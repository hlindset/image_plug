# preserve_hdr / ph HDR Preservation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire imgproxy's `preserve_hdr`/`ph` HDR-preservation policy through ImagePipe so a 16-bit source served as PNG/AVIF keeps its high bit depth instead of being tone-mapped to 8-bit SDR.

**Architecture:** The HDR working-colorspace machinery already exists as the "#121 seam" (`InputColorManagement.working_space/2` + `condition/2`, hardwired `supports_hdr?: false`). This plan adds a product-neutral `hdr: :tone_map | :preserve` field to `ImagePipe.Plan.Output`, a `Format.supports_hdr?/1` capability check, the imgproxy `ph` parser surface, the cache-key/ETag partition, and computes a `supports_hdr?` boolean in the Request/Output boundary (`output.hdr == :preserve ∧ Format.supports_hdr?(pre-resolved format)`) threaded as a plain boolean through `opts` into the seam — keeping the Transform boundary free of Output deps. Encoder is unchanged (bit depth is fixed at the processing stage; libvips carries it through `pngsave`/`heifsave`).

**Tech Stack:** Elixir, libvips via Vix/`image`, NimbleOptions, Boundary, ExUnit; Svelte/TypeScript + Vitest for the fiddle demo.

**Spec:** [docs/superpowers/specs/2026-06-11-preserve-hdr-design.md](../specs/2026-06-11-preserve-hdr-design.md)

**Conventions:**
- Run all tooling through mise: `mise exec -- mix ...`.
- Run a single test file: `mise exec -- mix test path/to/test.exs`.
- The Elixir gate is `mise run precommit`; the full gate incl. fiddle is `mise run precommit:demo` (use it because this change touches `fiddle/`).
- Per project testing guidelines (CLAUDE.md): do **not** write struct-default / impossible-misuse / name-policing tests. Some tasks are pure data additions verified by `mix compile` + downstream behavioral tests; those tasks say so explicitly rather than inventing a bogus test.
- Commit after each task.

---

### Task 1: `Format.supports_hdr?/1`

**Files:**
- Modify: `lib/image_pipe/format.ex:9` (add a module attribute) and after `:50` (add the function)
- Test: `test/image_pipe/format_test.exs` (create if absent; otherwise add a `describe`)

- [ ] **Step 1: Write the failing test**

`test/image_pipe/format_test.exs` already exists (`defmodule ImagePipe.FormatTest`, `alias ImagePipe.Format`, with a `supports_color_profile?/1` describe near `:67`). Add this `describe` block to it:

```elixir
  describe "supports_hdr?/1" do
    test "AVIF and PNG carry HDR; WebP and JPEG do not" do
      assert Format.supports_hdr?(:avif)
      assert Format.supports_hdr?(:png)
      refute Format.supports_hdr?(:webp)
      refute Format.supports_hdr?(:jpeg)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/format_test.exs`
Expected: FAIL — `function ImagePipe.Format.supports_hdr?/1 is undefined or private`.

- [ ] **Step 3: Add the module attribute**

In `lib/image_pipe/format.ex`, directly under the existing `@color_profile_formats` line (`:9`), add:

```elixir
  @hdr_formats [:avif, :png]
```

- [ ] **Step 4: Add the function**

In `lib/image_pipe/format.ex`, directly after `supports_color_profile?/1` (after `:50`), add:

```elixir
  @doc "Returns whether the output format can carry HDR (16-bit). Mirrors imgproxy's `SupportsHDR()` for the four output formats (AVIF/PNG true; WebP/JPEG false)."
  @spec supports_hdr?(output_format()) :: boolean()
  def supports_hdr?(format), do: format in @hdr_formats
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/format_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/format.ex test/image_pipe/format_test.exs
git commit -m "feat(format): add supports_hdr?/1 (AVIF/PNG carry HDR)"
```

---

### Task 2: `Plan.Output` gains the `hdr` field

**Files:**
- Modify: `lib/image_pipe/plan/output.ex`

This is a pure data addition (a new defaulted field). Per project testing guidelines we do **not** write a struct-default test; it is exercised by the parser tests (Task 3), cache-key tests (Task 4), and the request-boundary test (Task 6). Verification here is `mix compile --warnings-as-errors`.

- [ ] **Step 1: Add the field to the struct defaults**

In `lib/image_pipe/plan/output.ex`, change the `defstruct` (currently ending `color_profile: :strip`) to add `hdr: :tone_map`:

```elixir
  defstruct mode: :automatic,
            quality: :default,
            format_qualities: %{},
            strip_metadata: true,
            keep_copyright: true,
            color_profile: :strip,
            hdr: :tone_map
```

- [ ] **Step 2: Add the type**

In the same file, add the `hdr` type alias next to `color_profile` and the field to `@type t`:

```elixir
  @type color_profile :: :preserve_source | :strip | {:convert, term()}
  @type hdr :: :tone_map | :preserve
  @type t :: %__MODULE__{
          mode: :automatic | {:explicit, format()},
          quality: quality(),
          format_qualities: %{optional(format()) => quality()},
          strip_metadata: boolean(),
          keep_copyright: boolean(),
          color_profile: color_profile(),
          hdr: hdr()
        }
```

- [ ] **Step 3: Update the moduledoc resolved-values note**

In the `@moduledoc`, extend the sentence that lists resolved values so it reads (add `hdr`):

```
  `strip_metadata`, `keep_copyright`, `color_profile`, and `hdr` are resolved
  values (never `nil`): a parser resolves its config defaults / URL options into
  concrete values before building a plan (the imgproxy parser does this in
  `apply_request_defaults/2`). They drive the encoder's metadata finalize and the
  transform's HDR working-space decision.
```

- [ ] **Step 4: Verify it compiles**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean (no warnings about missing `hdr` keys, since it is defaulted).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plan/output.ex
git commit -m "feat(plan): add product-neutral hdr policy field to Plan.Output"
```

---

### Task 3: imgproxy `preserve_hdr` / `ph` parser surface

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex` (`@option_specs`, `scoped_assignments/2`, `parse_known_option` generic head, `parse_field`)
- Modify: `lib/image_pipe/parser/imgproxy/parsed_request.ex` (`@default_output`, `output_request()` type)
- Modify: `lib/image_pipe/parser/imgproxy/options.ex` (`apply_request_defaults/2`)
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex` (`output_plan/1`, both clauses)
- Modify: `lib/image_pipe/parser/imgproxy.ex` (`@imgproxy_schema`, `request_defaults/1`)
- Test: `test/parser/imgproxy_test.exs` (add a `ph` test, mirroring the existing metadata test at `:140`-`:171`)

- [ ] **Step 1: Write the failing test**

In `test/parser/imgproxy_test.exs`, add (place it right after the existing `sm/kcr/scp` parse test that ends near `:171`):

```elixir
  test "preserve_hdr (ph) threads onto Plan.Output.hdr and overrides config both ways" do
    # default: tone-map
    assert {:ok, %Plan{output: %Output{hdr: :tone_map}}} =
             Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg"), [])

    # ph:1 → preserve
    assert {:ok, %Plan{output: %Output{hdr: :preserve}}} =
             Imgproxy.parse(conn(:get, "/_/ph:1/plain/images/cat.jpg"), [])

    # long name preserve_hdr:1 → preserve
    assert {:ok, %Plan{output: %Output{hdr: :preserve}}} =
             Imgproxy.parse(conn(:get, "/_/preserve_hdr:1/plain/images/cat.jpg"), [])

    # ph:0 → tone-map
    assert {:ok, %Plan{output: %Output{hdr: :tone_map}}} =
             Imgproxy.parse(conn(:get, "/_/ph:0/plain/images/cat.jpg"), [])

    # config default true, URL ph:0 overrides → tone-map
    assert {:ok, %Plan{output: %Output{hdr: :tone_map}}} =
             Imgproxy.parse(
               conn(:get, "/_/ph:0/plain/images/cat.jpg"),
               imgproxy: [preserve_hdr: true]
             )

    # config default true, no URL option → preserve
    assert {:ok, %Plan{output: %Output{hdr: :preserve}}} =
             Imgproxy.parse(
               conn(:get, "/_/plain/images/cat.jpg"),
               imgproxy: [preserve_hdr: true]
             )

    # invalid boolean rejected — ImagePipe is stricter than imgproxy here, which
    # warns and treats an unparseable bool as false (200 + tone-map). This is the
    # house-wide policy for all boolean options (sm/kcr/scp/el/…), not a ph quirk;
    # the assertion pins ImagePipe's actual behavior, NOT imgproxy parity.
    assert {:error, _reason} =
             Imgproxy.parse(conn(:get, "/_/ph:maybe/plain/images/cat.jpg"), [])
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: FAIL — `ph` is an unknown option (parse error / the `hdr` field never becomes `:preserve`).

- [ ] **Step 3: Add the grammar option specs**

In `lib/image_pipe/parser/imgproxy/option_grammar.ex`, add to `@option_specs` (after the `keep_copyright`/`kcr` entries at `:63`-`:64`):

```elixir
    "keep_copyright" => {:keep_copyright, [:keep_copyright]},
    "kcr" => {:keep_copyright, [:keep_copyright]},
    "preserve_hdr" => {:preserve_hdr, [:preserve_hdr]},
    "ph" => {:preserve_hdr, [:preserve_hdr]}
```

- [ ] **Step 4: Route `:preserve_hdr` to the `:output` scope**

In the same file, add `:preserve_hdr` to the `scoped_assignments/2` `:output` guard (`:152`-`:154`). Write the guard list pre-broken across lines — the single-line form is 106 chars and `mix format` rewrites it to this shape anyway:

```elixir
  defp scoped_assignments(kind, assignments)
       when kind in [
              :format,
              :quality,
              :format_quality,
              :strip_metadata,
              :keep_copyright,
              :preserve_hdr
            ],
       do: {:output, assignments}
```

- [ ] **Step 5: Add `:preserve_hdr` to the generic `parse_known_option` head and a `parse_field` clause**

In the same file, add `:preserve_hdr` to the `kind in [...]` list of the generic `parse_known_option` head (`:165`-`:178`):

```elixir
  defp parse_known_option(kind, fields, args, segment)
       when kind in [
              :resizing_type,
              :width,
              :height,
              :min_width,
              :min_height,
              :enlarge,
              :format,
              :strip_metadata,
              :keep_copyright,
              :preserve_hdr
            ] do
    parse_exact_fields(fields, args, segment)
  end
```

And add a `parse_field/2` clause next to the other boolean fields (after `:keep_copyright` at `:355`):

```elixir
  defp parse_field(:keep_copyright, value), do: parse_boolean(value)
  defp parse_field(:preserve_hdr, value), do: parse_boolean(value)
```

- [ ] **Step 6: Seed the parsed-request default**

In `lib/image_pipe/parser/imgproxy/parsed_request.ex`, add `preserve_hdr: nil` to `@default_output` (`:6`-`:13`):

```elixir
  @default_output %{
    format: nil,
    quality: :default,
    format_qualities: %{},
    strip_metadata: nil,
    keep_copyright: nil,
    strip_color_profile: nil,
    preserve_hdr: nil
  }
```

And add to the `output_request()` type (`:30`-`:37`):

```elixir
          required(:strip_color_profile) => boolean() | nil,
          required(:preserve_hdr) => boolean() | nil
        }
```

- [ ] **Step 7: Resolve the default in `apply_request_defaults/2`**

In `lib/image_pipe/parser/imgproxy/options.ex`, extend `resolve_metadata_defaults/2` (`:322`-`:328`) to also resolve `preserve_hdr` (default `false`):

```elixir
  defp resolve_metadata_defaults(output, defaults) do
    strip = resolve_bool(output.strip_metadata, Keyword.get(defaults, :strip_metadata, true))
    keep = resolve_bool(output.keep_copyright, Keyword.get(defaults, :keep_copyright, true))
    preserve_hdr = resolve_bool(output.preserve_hdr, Keyword.get(defaults, :preserve_hdr, false))
    # keep_copyright is only meaningful when metadata is being stripped; force it
    # false otherwise so byte-identical outputs share one canonical cache key.
    %{output | strip_metadata: strip, keep_copyright: strip and keep, preserve_hdr: preserve_hdr}
  end
```

(No change needed to `apply_request_defaults/2`'s body — it already pipes `output` through `resolve_metadata_defaults/2`.)

- [ ] **Step 8: Translate to the plan field in `plan_builder.ex`**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, add `hdr:` to **both** `output_plan/1` clauses. Automatic clause (`:91`-`:101`):

```elixir
  defp output_plan(%{format: nil} = request) do
    {:ok,
     %Output{
       mode: :automatic,
       quality: request.quality,
       format_qualities: request.format_qualities,
       strip_metadata: request.strip_metadata,
       keep_copyright: request.keep_copyright,
       color_profile: color_profile_policy(request.strip_color_profile),
       hdr: hdr_policy(request.preserve_hdr)
     }}
  end
```

Explicit clause (`:106`-`:122`):

```elixir
        {:ok,
         %Output{
           mode: {:explicit, format},
           quality: request.quality,
           format_qualities: request.format_qualities,
           strip_metadata: request.strip_metadata,
           keep_copyright: request.keep_copyright,
           color_profile: color_profile_policy(request.strip_color_profile),
           hdr: hdr_policy(request.preserve_hdr)
         }}
```

And add the translation helper next to `color_profile_policy/1` (`:124`-`:126`):

```elixir
  defp hdr_policy(true), do: :preserve
  defp hdr_policy(false), do: :tone_map
  defp hdr_policy(nil), do: :tone_map
```

- [ ] **Step 9: Add the host-config option**

In `lib/image_pipe/parser/imgproxy.ex`, add `preserve_hdr` to `@imgproxy_schema` (after `strip_color_profile` at `:50`):

```elixir
                     strip_color_profile: [type: :boolean, default: true],
                     preserve_hdr: [type: :boolean, default: false],
                     smart_crop_face_detection: [type: :boolean, default: false]
```

And to `request_defaults/1` (`:178`-`:185`):

```elixir
  defp request_defaults(imgproxy_opts) do
    [
      auto_rotate: Keyword.get(imgproxy_opts, :auto_rotate, true),
      strip_metadata: Keyword.get(imgproxy_opts, :strip_metadata, true),
      keep_copyright: Keyword.get(imgproxy_opts, :keep_copyright, true),
      strip_color_profile: Keyword.get(imgproxy_opts, :strip_color_profile, true),
      preserve_hdr: Keyword.get(imgproxy_opts, :preserve_hdr, false)
    ]
  end
```

- [ ] **Step 10: Run the test to verify it passes**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: PASS (all `ph` assertions, including override-both-directions and invalid-boolean).

- [ ] **Step 11: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/ lib/image_pipe/parser/imgproxy.ex test/parser/imgproxy_test.exs
git commit -m "feat(imgproxy): parse preserve_hdr/ph into Plan.Output.hdr"
```

---

### Task 4: Cache key + ETag partition on `hdr`

**Files:**
- Modify: `lib/image_pipe/cache/key.ex` — `output_plan_data/2` (both clauses, `:103`-`:130`) and `output_data/3` automatic clause (`:134`-`:151`)
- Test: `test/parser/imgproxy_test.exs` (extend the existing `sm/kcr/scp produce distinct cache keys` test at `:173`)

There are **three** insertion sites: the cache key uses `output_data/3` (automatic) which delegates its explicit path to `output_plan_data/2`; the ETag uses `output_plan_data/2` directly (via `plan_material/2`). All three must carry `hdr`.

- [ ] **Step 1: Write the failing test**

In `test/parser/imgproxy_test.exs`, extend the `sm/kcr/scp produce distinct cache keys` test (`:173`-`:190`) by adding `ph` assertions before the final `end`:

```elixir
    refute base == key.("/_/sm:1/kcr:1/scp:1/ph:1/plain/images/cat.jpg")

    # explicit output format keys through the same output material
    refute key.("/_/f:png/ph:0/plain/images/cat.jpg") ==
             key.("/_/f:png/ph:1/plain/images/cat.jpg")
```

(Keep the existing `base` and the explicit-`f:jpeg` assertions; just add the two `refute`s above. `base` is built from `/_/sm:1/kcr:1/scp:1/...` and the new `ph:1` URL differs only by the HDR policy.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs -k "distinct cache keys"`
Expected: FAIL — the `ph:0` and `ph:1` keys are equal (hdr not yet in the key material).

- [ ] **Step 3: Add `hdr` to the ETag material (both `output_plan_data/2` clauses)**

In `lib/image_pipe/cache/key.ex`, automatic clause (`:103`-`:117`) — add `hdr: output.hdr` after `keep_copyright`:

```elixir
       strip_metadata: output.strip_metadata,
       color_profile: output.color_profile,
       keep_copyright: output.keep_copyright,
       hdr: output.hdr
     ]}
```

Explicit clause (`:119`-`:130`) — same addition after `keep_copyright`:

```elixir
       strip_metadata: output.strip_metadata,
       color_profile: output.color_profile,
       keep_copyright: output.keep_copyright,
       hdr: output.hdr
     ]}
```

- [ ] **Step 4: Add `hdr` to the cache-key material (`output_data/3` automatic clause)**

In the same file, `output_data/3` automatic clause (`:134`-`:151`) — add `hdr: output.hdr` after `keep_copyright`:

```elixir
       strip_metadata: output.strip_metadata,
       color_profile: output.color_profile,
       keep_copyright: output.keep_copyright,
       hdr: output.hdr
     ]}
```

(The explicit `output_data/3` path at `:153` delegates to `output_plan_data/2`, so it is already covered by Step 3. Do **not** bump `@schema_version` or `@transform_key_data_version` — greenfield reshape in place.)

- [ ] **Step 5: Run the test to verify it passes**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs -k "distinct cache keys"`
Expected: PASS.

- [ ] **Step 6: Update the five exact key-material fixtures in `key_test.exs`**

`test/image_pipe/cache/key_test.exs` has **five** assertions that pin the *full* `output` keyword list with `==`; each will now fail because the list gains `hdr`. They are at lines **210, 950, 983, 1032, 1084**, and each block ends:

```elixir
               strip_metadata: true,
               color_profile: :strip,
               keep_copyright: true
             ],
```

In all five, add `hdr: :tone_map` after `keep_copyright: true` (the lists are order-sensitive literals; `hdr` must come last to match the production order from Step 3/4):

```elixir
               strip_metadata: true,
               color_profile: :strip,
               keep_copyright: true,
               hdr: :tone_map
             ],
```

(`test/image_pipe/cache/key_property_test.exs` needs no change — its `data_one`/`data_two` literals are hand-built for canonicalization symmetry, and its generators compare only hashes.)

- [ ] **Step 7: Run the cache key suite for regressions**

Run: `mise exec -- mix test test/image_pipe/cache/key_test.exs test/image_pipe/cache/key_property_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/cache/key.ex test/image_pipe/cache/key_test.exs test/parser/imgproxy_test.exs
git commit -m "feat(cache): partition cache key + ETag on HDR policy"
```

---

### Task 5: Resolve `supports_hdr?` and thread it to the seam

**Files:**
- Modify: `lib/image_pipe/output/policy.ex` (new `supports_hdr?/3` helper)
- Modify: `lib/image_pipe/request/source_session/producer.ex` (compute + inject into `opts`)
- Modify: `lib/image_pipe/transform/plan_executor.ex` (`seed_color_management/2` passes `opts`; `run_color_management/2` reads the flag)
- Modify: `lib/image_pipe/transform/input_color_management.ex` (update the stale "#121 seam / hardwired false" moduledoc)
- Test: `test/image_pipe/output_policy_test.exs` (the EXISTING `ImagePipe.Output.PolicyTest` — add a `describe`)

- [ ] **Step 1: Write the failing helper test**

The test module already exists at `test/image_pipe/output_policy_test.exs` (flat path, **not** `output/policy_test.exs` — do not create a new file or you redefine the module). It already has `import Plug.Test`, `import Plug.Conn`, `alias …Output.Policy`, `alias …Plan.Output` (`:4`-`:9`). Add this `describe` block to it:

```elixir
  describe "supports_hdr?/3" do
    test "true only when policy is :preserve and the resolved format carries HDR" do
      conn = conn(:get, "/")

      png = Policy.from_output_plan(conn, %Output{mode: {:explicit, :png}}, [])
      jpeg = Policy.from_output_plan(conn, %Output{mode: {:explicit, :jpeg}}, [])

      preserve = %Output{mode: {:explicit, :png}, hdr: :preserve}
      tone_map = %Output{mode: {:explicit, :png}, hdr: :tone_map}

      # PNG carries HDR
      assert Policy.supports_hdr?(png, preserve, :png)
      # tone_map policy never preserves
      refute Policy.supports_hdr?(png, tone_map, :png)
      # JPEG cannot carry HDR even when preserve is requested
      refute Policy.supports_hdr?(jpeg, %{preserve | mode: {:explicit, :jpeg}}, :jpeg)
    end

    test "false when the format is only resolvable from the post-transform image (conservative tone-map)" do
      # automatic mode + no modern Accept + modern source → :needs_final_image_alpha → false
      conn = conn(:get, "/")
      policy = Policy.from_output_plan(conn, %Output{mode: :automatic}, [])
      preserve = %Output{mode: :automatic, hdr: :preserve}

      refute Policy.supports_hdr?(policy, preserve, :avif)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: FAIL — `function ImagePipe.Output.Policy.supports_hdr?/3 is undefined`.

- [ ] **Step 3: Implement the helper**

In `lib/image_pipe/output/policy.ex`, add (after `resolve/2`, near `:97`). `Format`, `Resolved`, and `Output` are already aliased in this module:

```elixir
  @doc """
  Whether the HDR working space should be kept (`Plan.Output.hdr == :preserve`
  and the output format carries HDR). Computed pre-transform so it can seed the
  input-color-management stage. In the one branch where the format is only known
  after the transform (`:needs_final_image_alpha`), returns `false` — the
  conservative tone-map (see the design doc, decision 2).
  """
  @spec supports_hdr?(t(), Output.t(), source_format() | nil) :: boolean()
  def supports_hdr?(%__MODULE__{} = policy, %Output{hdr: :preserve}, source_format) do
    case resolve(policy, source_format) do
      {:ok, %Resolved{format: format}} -> Format.supports_hdr?(format)
      _other -> false
    end
  end

  def supports_hdr?(%__MODULE__{}, %Output{}, _source_format), do: false
```

- [ ] **Step 4: Run the helper test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/output_policy_test.exs`
Expected: PASS.

- [ ] **Step 5: Inject the boolean in the producer**

`lib/image_pipe/request/source_session/producer.ex` **already aliases** `ImagePipe.Output.Policy` (at `:7`) — do NOT add a second alias (a duplicate triggers `unused alias`, which the gate's `--warnings-as-errors` fails on).

In `prepare_first_chunk/1` (`:114`-`:153`), change the transform call. The `decoded` binding and `request.output_policy` are already in scope. Replace the `process_decoded_source` clause (`:122`-`:123`) with one that computes the flag inline (mirroring the existing `limits = …` plain binding at `:131`):

```elixir
           {:ok, %State{} = final_state} <-
             Processor.process_decoded_source(
               decoded,
               request.plan,
               Keyword.put(
                 request.opts,
                 :supports_hdr?,
                 Policy.supports_hdr?(request.output_policy, request.plan.output, decoded.source_format)
               )
             ),
```

- [ ] **Step 6: Thread `opts` through the seam in `plan_executor.ex`**

In `lib/image_pipe/transform/plan_executor.ex`, `seed_color_management/2` (`:87`-`:95`) — pass `opts` into `run_color_management`:

```elixir
  defp seed_color_management(%State{telemetry_opts: telemetry_opts} = state, opts) do
    if Keyword.get(opts, :seed_orientation, false) do
      Telemetry.span(telemetry_opts, [:transform, :input_color_management], %{}, fn ->
        run_color_management(state, opts)
      end)
    else
      {:ok, state}
    end
  end
```

And `run_color_management/1` → `/2` (`:97`-`:109`) — read the flag and use it in both spots:

```elixir
  defp run_color_management(%State{image: image} = state, opts) do
    hdr? = Keyword.get(opts, :supports_hdr?, false)
    working_space = InputColorManagement.working_space(VipsImage.interpretation(image), hdr?)

    case InputColorManagement.condition(state, supports_hdr?: hdr?) do
      {:ok, %State{} = new_state} ->
        {{:ok, new_state},
         %{result: :ok, working_space: working_space, imported?: new_state.color_imported?}}

      {:error, {InputColorManagement, reason}} ->
        {{:error, {:decode, reason}},
         %{result: :processing_error, working_space: working_space, imported?: false}}
    end
  end
```

- [ ] **Step 7: Update the stale `input_color_management.ex` moduledoc**

In `lib/image_pipe/transform/input_color_management.ex`, the `@moduledoc` (`:1`-`:8`) still says *"`supports_hdr?` is hardwired `false` today (the #121 seam)."* — now false after this task. Replace that sentence so it reads as if the seam was always wired (per the CLAUDE.md clean-removal rule — no narration of the change):

```elixir
  imports the embedded ICC profile into a working space before any processing
  step, mirroring imgproxy's `colorspaceToProcessing`. Seeded once by
  `ImagePipe.Transform.PlanExecutor`, which passes `supports_hdr?` (resolved in
  the Request/Output boundary from `Plan.Output.hdr` and the output format's HDR
  capability).
```

- [ ] **Step 8: Verify compile + architecture boundaries hold**

Run: `mise exec -- mix compile --warnings-as-errors`
Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: compiles clean (no duplicate-alias warning); boundary tests PASS (Transform received only a plain boolean; no new Output reference).

- [ ] **Step 9: Commit**

```bash
git add lib/image_pipe/output/policy.ex lib/image_pipe/request/source_session/producer.ex lib/image_pipe/transform/plan_executor.ex lib/image_pipe/transform/input_color_management.ex test/image_pipe/output_policy_test.exs
git commit -m "feat(request): resolve supports_hdr? and thread it to the color seam"
```

---

### Task 6: Request-boundary pixel test (preserved vs tone-mapped)

**Files:**
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs` (add an `Hdr16OriginImage` plug + a test)

This is the acceptance-criteria headline. It makes real `ImagePipe.call/2` requests against the genuine 16-bit `rgb16.png` fixture and asserts the decoded body's band format: `USHORT` when HDR is preserved, `UCHAR` when tone-mapped. The tone-map baseline is the **same request with `ph:0`** (driving the pipeline's own colourspace collapse) — never a hand-cast image.

- [ ] **Step 1: Add the origin plug**

In `test/image_pipe/imgproxy_wire_conformance_test.exs`, add this module next to the other origin plugs (e.g. after `CmykOriginImage` near `:348`):

```elixir
  defmodule Hdr16OriginImage do
    @moduledoc false
    # Serves the committed genuine-16-bit RGB PNG fixture (interpretation RGB16).
    def call(conn, _opts) do
      body = File.read!("test/support/image_pipe/test/imgproxy_differential/sources/rgb16.png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end
```

- [ ] **Step 2: Add the module-level opts attribute and band-format helper**

ExUnit forbids `@module_attr` and `defp` *inside* a `describe` block, so add both at module level. Put the attribute next to the other `@..._opts` near `@default_opts` (`:587`), and the helper next to `decoded_image/1` (`:3281`):

```elixir
  @hdr_opts [
    parser: ImagePipe.Parser.Imgproxy,
    sources: [
      path:
        {RootHTTPAdapter,
         root_url: "http://origin.test", req_options: [plug: Hdr16OriginImage]}
    ]
  ]
```

```elixir
  defp band_format(%Plug.Conn{} = conn) do
    {:ok, format} = VipsImage.header_value(decoded_image(conn), "format")
    format
  end
```

- [ ] **Step 3: Write the failing test**

Add this `describe` block in the metadata/color area (`call_imgproxy/2`, `decoded_image/1`, and `VipsImage` are already in scope; `@hdr_opts`/`band_format/1` come from Step 2):

```elixir
  describe "preserve_hdr (ph)" do
    test "PNG output preserves 16-bit with ph:1 and tone-maps to 8-bit with ph:0" do
      preserved = call_imgproxy("/_/ph:1/f:png/plain/images/rgb16.png", @hdr_opts)
      tonemapped = call_imgproxy("/_/ph:0/f:png/plain/images/rgb16.png", @hdr_opts)

      assert preserved.status == 200
      assert tonemapped.status == 200
      assert band_format(preserved) == :VIPS_FORMAT_USHORT
      assert band_format(tonemapped) == :VIPS_FORMAT_UCHAR
    end

    test "ph:1 preserves 16-bit with no geometry option" do
      conn = call_imgproxy("/_/ph:1/f:png/plain/images/rgb16.png", @hdr_opts)

      assert conn.status == 200
      assert band_format(conn) == :VIPS_FORMAT_USHORT
    end

    test "JPEG output tone-maps even with ph:1 (per-format fallback)" do
      conn = call_imgproxy("/_/ph:1/f:jpeg/plain/images/rgb16.png", @hdr_opts)

      assert conn.status == 200
      assert band_format(conn) == :VIPS_FORMAT_UCHAR
    end
  end
```

- [ ] **Step 4: Run test to verify it fails, then passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs -k "preserve_hdr"`

At this point in the plan (Tasks 1-5 done) it should **PASS**. If you are running this task in isolation before the wiring lands, expect FAIL with `band_format(preserved) == :VIPS_FORMAT_UCHAR` (HDR not preserved). Confirm the failure mode is the band-format mismatch (not a 4xx/decoupled error), then ensure Tasks 1-5 are applied.

Expected (with full plan applied): PASS.

- [ ] **Step 5: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(imgproxy): request-boundary preserved-vs-tonemapped HDR pixel test"
```

---

### Task 7: Telemetry Logger + docs sync

**Files:**
- Test: `test/image_pipe/telemetry/logger_test.exs` (add an HDR working-space rendering assertion)
- Modify: `docs/telemetry.md` (note the new possible `working_space` values)

No Logger code change is needed (the `[:transform, :input_color_management]` span and its `working_space` rendering already exist at `lib/image_pipe/telemetry/logger.ex:160`). But the observable rendered value can now be `RGB16`/`GREY16`, which the telemetry guidelines require pinning with a test + doc note.

- [ ] **Step 1: Write the failing test**

In `test/image_pipe/telemetry/logger_test.exs`, add next to the existing `input_color_management` tests (near `:249`-`:264`), mirroring that pattern:

```elixir
  test "logs input_color_management preserved HDR working space" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :input_color_management, :stop],
          %{duration: 500},
          %{result: :ok, working_space: :VIPS_INTERPRETATION_RGB16, imported?: false}
        )
      end)

    assert log =~ "transform input_color_management: ok"
    assert log =~ "VIPS_INTERPRETATION_RGB16"
  end
```

(This mirrors the existing "logs input_color_management success at base level with working space" test at `:249`-`:264` verbatim, only changing `working_space` to the RGB16 atom and the assertion.)

- [ ] **Step 2: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/telemetry/logger_test.exs -k "preserved HDR"`
Expected: PASS immediately (the Logger already renders `working_space`); this test pins the HDR rendering so a future Logger refactor can't silently drop it.

- [ ] **Step 3: Update `docs/telemetry.md`**

In `docs/telemetry.md`, in the `:working_space` bullet (near `:143`), note the HDR values. Change it to read:

```
- `:working_space` — the VIPS interpretation atom of the resolved working
  colorspace (e.g. `:VIPS_INTERPRETATION_sRGB`/`:VIPS_INTERPRETATION_B_W` for
  tone-mapped SDR, or `:VIPS_INTERPRETATION_RGB16`/`:VIPS_INTERPRETATION_GREY16`
  when an HDR source is preserved under `preserve_hdr`).
```

- [ ] **Step 4: Commit**

```bash
git add test/image_pipe/telemetry/logger_test.exs docs/telemetry.md
git commit -m "test(telemetry): pin HDR working-space rendering; sync telemetry docs"
```

---

### Task 8: Support matrix documentation (all three axes)

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Surface axis — option + config rows**

Change the option row (search for the line `| \`preserve_hdr\` | \`ph\` | Missing |`, near `:778`) to:

```
| `preserve_hdr` | `ph` | Supported | HDR-preservation policy. `ph:1` keeps a 16-bit source (RGB16/GREY16) in a 16-bit working space through processing and encode when the output format carries HDR (AVIF, PNG); WebP/JPEG always tone-map to 8-bit. Default (`ph:0`) tone-maps to 8-bit SDR. Resolves to `Plan.Output.hdr` (`:preserve`/`:tone_map`); URL overrides the `preserve_hdr` host-config default both directions. |
```

And change the `IMGPROXY_PRESERVE_HDR` config bullet (near `:475`, currently `⭕ \`IMGPROXY_PRESERVE_HDR\``) to mark it supported, default off:

```
- ✅ `IMGPROXY_PRESERVE_HDR` — host-config default for the HDR policy (`preserve_hdr` parser option); default `false` (tone-map).
```

- [ ] **Step 2: Stage/order axis — stage-4 row**

Extend the stage-4 `colorspaceToProcessing` row (near `:82`). Append to its Notes cell:

```
 The working-space chooser now consumes the resolved HDR policy (`Format.supports_hdr?(format)` ∧ `Plan.Output.hdr == :preserve`), threaded as a pre-transform `supports_hdr?` boolean from the Request/Output boundary; previously hardwired SDR (the #121 seam). For 16-bit sources this keeps RGB16/GREY16 when the format carries HDR, else collapses to sRGB/B_W.
```

- [ ] **Step 3: Behavioral/pixel axis — per-format table + divergence note**

Add, near the stage-4 notes (or in a short "HDR preservation" Diverges subsection), the per-format fallback table and the divergence note:

```markdown
**HDR preservation (`preserve_hdr` / `ph`).** For a 16-bit source:

| Output | `ph:1` effect |
| --- | --- |
| AVIF | preserved (16-bit working space → high-bit-depth encode) |
| PNG  | preserved (16-bit PNG) |
| WebP | tone-mapped to 8-bit (`Format.supports_hdr?` false) |
| JPEG | tone-mapped to 8-bit (`Format.supports_hdr?` false) |

`ph:1` is a no-op for 8-bit sources regardless of format (matches imgproxy).

**Diverges:** imgproxy resolves the output format *before* processing (predicting
transparency from the source), so `SupportsHDR()` is always definitive. ImagePipe
resolves format *after* the transform when negotiation depends on the processed
image's alpha (`:source` mode + no modern `Accept` + modern source →
PNG-if-alpha/JPEG-if-not). In that one branch ImagePipe conservatively
tone-maps (`supports_hdr?` = false). For all other cases — explicit format, a
modern `Accept` candidate (incl. AVIF), or a jpeg/png passthrough source —
`supports_hdr?` is resolved pre-transform and matches imgproxy. Note also that
upstream `saveImage` has an AVIF-`<16px` → PNG/JPEG fallback that runs after the
HDR working space is fixed, so imgproxy itself can process 16-bit then save 8-bit
in that corner.
```

- [ ] **Step 4: Verify markdown renders / no broken table**

Run: `mise exec -- mix docs` is not required; just visually confirm the tables are well-formed (pipes balanced). Optionally grep: `grep -n "preserve_hdr" docs/imgproxy_support_matrix.md` and confirm the row is now `Supported`.

- [ ] **Step 5: Commit**

```bash
git add docs/imgproxy_support_matrix.md
git commit -m "docs(imgproxy): mark preserve_hdr Supported across all three matrix axes"
```

---

### Task 9: Fiddle demo controls + URL round-trip

**Files:**
- Modify: `fiddle/assets/processing-path.ts` (DemoState type `:196`-`:198`, `defaultDemoState` `:392`-`:394`, `optionSegments` `:551`-`:553`)
- Modify: `fiddle/assets/App.svelte` (`metadataSegments` `:218`-`:232`, the switch section near `:1519`-`:1524`)
- Modify: `fiddle/assets/demo-url-state.ts` (the `case` dispatch `:278`-`:279`, a new `parsePreserveHdr` near `:955`)
- Modify: `fiddle/assets/processing-path.test.ts` (add a `ph:1` round-trip test)

- [ ] **Step 1: Add the state field + default + URL segment in `processing-path.ts`**

Add to the `DemoState` type, after `stripColorProfile: boolean;` (`:198`):

```typescript
  stripColorProfile: boolean;
  preserveHdr: boolean;
```

Add to `defaultDemoState`, after `stripColorProfile: true,` (`:394`):

```typescript
  stripColorProfile: true,
  preserveHdr: false,
```

Add to `optionSegments`, after the `scp:0` block (`:551`-`:553`):

```typescript
  if (!currentState.stripColorProfile) {
    segments.push("scp:0");
  }

  if (currentState.preserveHdr) {
    segments.push("ph:1");
  }
```

- [ ] **Step 2: Mirror the segment in `App.svelte`'s `metadataSegments`**

In `fiddle/assets/App.svelte`, add to `metadataSegments` after the `scp:0` block (`:227`-`:229`):

```typescript
    if (!currentState.stripColorProfile) {
      segs.push("scp:0");
    }

    if (currentState.preserveHdr) {
      segs.push("ph:1");
    }
```

- [ ] **Step 3: Add the switch control in `App.svelte`**

After the "Strip color profile (scp)" switch label (`:1519`-`:1524`), add:

```svelte
        <label class="switch-field">
          <Switch.Root class="switch-root" bind:checked={state.stripColorProfile}>
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
          <span>Strip color profile (scp)</span>
        </label>

        <label class="switch-field">
          <Switch.Root class="switch-root" bind:checked={state.preserveHdr}>
            <Switch.Thumb class="switch-thumb" />
          </Switch.Root>
          <span>Preserve HDR (ph)</span>
        </label>
```

- [ ] **Step 4: Add the reverse-parse route + setter in `demo-url-state.ts`**

Add the dispatch case after `case "scp":` (`:278`-`:279`):

```typescript
    case "scp":
      return parseStripColorProfile(currentState, args);

    case "ph":
      return parsePreserveHdr(currentState, args);
```

And add the setter next to `parseStripColorProfile` (after `:970`):

```typescript
function parsePreserveHdr(currentState: DemoState, args: string[]): DemoState | null {
  if (args.length !== 1) {
    return null;
  }

  const value = parseBooleanValue(args[0]);

  if (value === null) {
    return null;
  }

  return {
    ...currentState,
    preserveHdr: value,
  };
}
```

- [ ] **Step 5: Add the round-trip test in `processing-path.test.ts`**

Mirror the existing `parseDemoPath(demoPathForState(state))` round-trip pattern (e.g. the gravity round-trip tests near `:580`). `optionSegments`, `defaultDemoState`, `parseDemoPath`, and `demoPathForState` are all already imported at the top of the file (`:3`-`:30`). Add:

```typescript
  it("round-trips ph:1 through the demo path", () => {
    const state = { ...defaultDemoState, preserveHdr: true };

    expect(optionSegments(state)).toContain("ph:1");

    const parsed = parseDemoPath(demoPathForState(state));
    expect(parsed).toMatchObject({ preserveHdr: true });
  });
```

- [ ] **Step 6: Run the fiddle JS checks**

Run: `mise exec -- pnpm -C fiddle test`
Then: `mise exec -- pnpm -C fiddle check` (svelte-check / tsc)
Expected: PASS — the new field typechecks and the round-trip test passes.

- [ ] **Step 7: Commit**

```bash
git add fiddle/assets/processing-path.ts fiddle/assets/App.svelte fiddle/assets/demo-url-state.ts fiddle/assets/processing-path.test.ts
git commit -m "feat(fiddle): add Preserve HDR (ph) toggle with URL round-trip"
```

---

### Task 10: Full gate

**Files:** none (verification only)

- [ ] **Step 1: Run the Elixir + fiddle gate**

Run: `mise run precommit:demo`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`, and the fiddle JS test/check/lint/format/build all PASS.

- [ ] **Step 2: Fix any formatting**

If `mix format --check-formatted` fails, run `mise exec -- mix format` and re-run the gate; commit the formatting fix:

```bash
git add -A
git commit -m "chore: mix format"
```

- [ ] **Step 3: Final spec cross-check**

Re-read [the spec](../specs/2026-06-11-preserve-hdr-design.md) acceptance-criteria mapping and confirm each item has a landed task: parser/planner tests (Task 3), request-boundary preserved-vs-tonemapped (Task 6), documented default + per-format fallback (Task 8), docs + demo controls (Tasks 8, 9), cache-key/ETag partition (Task 4). Confirm no `Plan.Output` field default was left at the wrong value (`hdr: :tone_map`) and `preserve_hdr` host-config defaults to `false`.

---

## Notes for the implementer

- **#119 (cp/icc) may land first or second.** It also adds a `Plan.Output` field, a parser option row, a matrix row, and a fiddle switch. Conflicts will be additive (a second field / row / switch), not semantic. If you hit a rebase conflict in `output.ex`, `option_grammar.ex`, `parsed_request.ex`, `plan_builder.ex`, `cache/key.ex`, the matrix, or the fiddle, resolve by keeping both fields/rows/switches.
- **Do not bump cache `@schema_version`/`@transform_key_data_version`** (greenfield reshape in place).
- **Encoder is intentionally untouched.** If the Task 6 test shows `UCHAR` for a preserved PNG, the bug is upstream of the encoder (the `supports_hdr?` boolean or the seam wiring in Task 5), not in `Output.Encoder`.
