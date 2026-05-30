# Imgproxy Metadata & Color-Profile Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement imgproxy's `strip_metadata` (`sm`), `keep_copyright` (`kcr`), and `strip_color_profile` (`scp`) controls — default-on, parser-owned defaults, URL overrides — closing the EXIF/XMP/GPS privacy gap (#30).

**Architecture:** `sm`/`kcr` are encode-time metadata policy on `ImagePipe.Plan.Output`, threaded `Policy → Resolved → Encoder` and applied with Vix `mutate` (explicit field names). `scp` is a product-neutral transform op `NormalizeColorProfile` (mirroring `AutoOrient`), positioned after geometry and before the effect chain, cache-keyed as a pipeline op. All four metadata/orientation defaults (`auto_rotate`, `strip_metadata`, `keep_copyright`, `strip_color_profile`) live in the imgproxy parser config.

**Tech Stack:** Elixir, `image`/Vix (libvips), NimbleOptions, ExUnit, Boundary; demo is Svelte/TypeScript.

**Reference spec:** `docs/superpowers/specs/2026-05-30-imgproxy-metadata-color-profile-design.md`

**Verified library facts (do not re-derive):**
- `Image.to_colorspace/3` (`image, :srgb, opts`) is ICC-aware (`Vix.Vips.Operation.icc_transform`). The 2-arity `to_colorspace/2` is interpretation-only — **do not use it**.
- `Image.remove_metadata(img, :xmp)` is a **no-op** (`image` v0.67 maps `:xmp` → `"xmp-dataa"`, a typo). Use explicit string field names.
- `Image.minimize_metadata/1,2` and default `remove_metadata/1` remove **all** header fields **including `icc-profile-data`**. Preserve the profile explicitly where needed.
- `Vix.Vips.Image.header_field_names/1` lists fields; `Vix.Vips.MutableImage.remove/2` removes one by name.

**Run commands from the worktree root.** Use `mise exec -- mix ...` (deps are installed in the main checkout; if the worktree lacks deps, run `mise run setup` first).

---

## File Structure

**Create:**
- `lib/image_pipe/plan/operation/normalize_color_profile.ex` — semantic op (no fields).
- `lib/image_pipe/transform/operation/normalize_color_profile.ex` — executable op (ICC→sRGB + drop profile).

**Modify (Elixir):**
- `lib/image_pipe/plan/operation.ex` — `normalize_color_profile/0` constructor, `semantic?/1` clause, type union.
- `lib/image_pipe/transform.ex` — Boundary `exports:` add `Operation.NormalizeColorProfile`.
- `lib/image_pipe/transform/plan_executor.ex` — lowering clause.
- `lib/image_pipe/plan/key_data.ex` — alias + `data/1` clause.
- `lib/image_pipe/plan/output.ex` — `strip_metadata`/`keep_copyright` fields.
- `lib/image_pipe/parser/imgproxy.ex` — config schema + `request_defaults/1`.
- `lib/image_pipe/parser/imgproxy/option_grammar.ex` — option specs, scope, boolean parsing, `scp` special option.
- `lib/image_pipe/parser/imgproxy/parsed_request.ex` — `@default_output` adds `strip_metadata`/`keep_copyright`.
- `lib/image_pipe/parser/imgproxy/pipeline_request.ex` — `strip_color_profile`/`strip_color_profile_requested` fields.
- `lib/image_pipe/parser/imgproxy/options.ex` — `update_current_pipeline` scp branch, `apply_request_defaults` resolves sm/kcr/scp.
- `lib/image_pipe/parser/imgproxy/plan_builder.ex` — `output_plan/1` sets sm/kcr; `plan_geometry/1` inserts color-profile op.
- `lib/image_pipe/output/policy.ex` — thread sm/kcr.
- `lib/image_pipe/output/resolved.ex` — sm/kcr fields.
- `lib/image_pipe/output/encoder.ex` — finalize (strip metadata).
- `lib/image_pipe/cache/key.ex` — `output_plan_data/2` adds sm/kcr.
- `docs/imgproxy_support_matrix.md`, `docs/transform_operations.md` — docs.

**Modify (demo):**
- `demo/src/processing-path.ts` — `DemoState` fields + defaults + `optionSegments` emit.
- `demo/src/demo-url-state.ts` — parse `sm`/`kcr`/`scp`.
- `demo/src/App.svelte` — "Metadata & Color" controls.

**Tests:**
- `test/parser/imgproxy_test.exs` — parse→plan for sm/kcr/scp.
- `test/image_pipe/imgproxy_wire_conformance_test.exs` — wire tests + metadata/wide-gamut origin generators.
- `test/image_pipe/architecture_boundary_test.exs` — add new export to assertion.

---

## Task 1: `NormalizeColorProfile` operation + plumbing

**Files:**
- Create: `lib/image_pipe/plan/operation/normalize_color_profile.ex`
- Create: `lib/image_pipe/transform/operation/normalize_color_profile.ex`
- Modify: `lib/image_pipe/plan/operation.ex`, `lib/image_pipe/transform.ex`, `lib/image_pipe/transform/plan_executor.ex`, `lib/image_pipe/plan/key_data.ex`
- Test: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Add the new export to the architecture boundary test (failing test)**

In `test/image_pipe/architecture_boundary_test.exs`, add to the `assert_boundary_exports_include(transform, [...])` list (after `ImagePipe.Transform.Operation.Saturation`):

```elixir
      ImagePipe.Transform.Operation.Saturation,
      ImagePipe.Transform.Operation.NormalizeColorProfile
```

- [ ] **Step 2: Run it to verify failure**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: FAIL — `ImagePipe.Transform.Operation.NormalizeColorProfile` is not exported / does not exist.

- [ ] **Step 3: Create the semantic plan operation**

Create `lib/image_pipe/plan/operation/normalize_color_profile.ex`:

```elixir
defmodule ImagePipe.Plan.Operation.NormalizeColorProfile do
  @moduledoc """
  Semantic request to normalize the image to sRGB and drop the embedded ICC
  profile. Product-neutral; the imgproxy `strip_color_profile` (`scp`) option
  maps to this. A future target-profile field is the `cp` (#119) seam.
  """

  defstruct []

  @type t :: %__MODULE__{}
end
```

- [ ] **Step 4: Create the executable transform operation**

Create `lib/image_pipe/transform/operation/normalize_color_profile.ex`:

```elixir
defmodule ImagePipe.Transform.Operation.NormalizeColorProfile do
  @moduledoc """
  Executable color-profile normalization: convert the embedded ICC profile to
  sRGB (ICC-aware, via `Image.to_colorspace/3` -> `icc_transform`) and drop the
  profile so the output embeds none. No-op when the image carries no profile.
  """

  @behaviour ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State

  @icc_field "icc-profile-data"

  defstruct []

  @type t :: %__MODULE__{}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :normalize_color_profile

  @impl ImagePipe.Transform
  def execute(%__MODULE__{}, %State{} = state) do
    case normalize(state.image) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp normalize(image) do
    if profile?(image) do
      Image.to_colorspace(image, :srgb, [])
    else
      {:ok, image}
    end
  end

  defp profile?(image) do
    case Vix.Vips.Image.header_field_names(image) do
      {:ok, names} -> @icc_field in names
      _ -> false
    end
  end
end
```

> **R1 (post-review):** the op is **conversion-only** — it does NOT drop the
> `icc-profile-data` header. Metadata removal requires `Vix` `mutate` →
> `copy_memory`, which inside the lazy chain crashes the producer (500) on
> corrupt sources instead of degrading to 415 (and `Chain.execute` re-tags op
> errors as `:transform_error` → 500 anyway). The profile-header drop happens at
> the encoder finalize (Task 5), which realizes catchably before any `mutate`.
> The `@icc_field` module attribute is still used by `profile?/1`.

- [ ] **Step 5: Add the constructor, type, and `semantic?/1` clause in `plan/operation.ex`**

Add a `NormalizeColorProfile` alias near the other operation aliases. Add to the `@type semantic_operation` union (append `| NormalizeColorProfile.t()`). Add a constructor next to `auto_orient/0`:

```elixir
  @spec normalize_color_profile() :: NormalizeColorProfile.t()
  def normalize_color_profile, do: %NormalizeColorProfile{}
```

Add the `semantic?/1` clause beside `semantic?(%AutoOrient{})`:

```elixir
  def semantic?(%NormalizeColorProfile{}), do: true
```

- [ ] **Step 6: Export from the Transform boundary**

In `lib/image_pipe/transform.ex`, add to the `exports:` list after `Operation.Saturation`:

```elixir
      Operation.Saturation,
      Operation.NormalizeColorProfile
```

- [ ] **Step 7: Add the KeyData clause**

In `lib/image_pipe/plan/key_data.ex`, add the alias (alphabetical, after `Monochrome`):

```elixir
  alias ImagePipe.Plan.Operation.NormalizeColorProfile
```

Add the `data/1` clause beside the `AutoOrient` clause:

```elixir
  def data(%NormalizeColorProfile{}), do: [op: :normalize_color_profile]
```

- [ ] **Step 8: Add the PlanExecutor lowering clause**

In `lib/image_pipe/transform/plan_executor.ex`, add aliases for both the plan op and the executable op (follow the existing alias style, e.g. `PlanAutoOrient`/`AutoOrient`):

```elixir
  alias ImagePipe.Plan.Operation.NormalizeColorProfile, as: PlanNormalizeColorProfile
  alias ImagePipe.Transform.Operation.NormalizeColorProfile
```

Add the lowering clause beside the `AutoOrient` clause:

```elixir
  defp executable_operations(%PlanNormalizeColorProfile{}, %State{}, _context),
    do: [%NormalizeColorProfile{}]
```

- [ ] **Step 9: Run the boundary test + compile**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/image_pipe/plan/operation/normalize_color_profile.ex \
        lib/image_pipe/transform/operation/normalize_color_profile.ex \
        lib/image_pipe/plan/operation.ex lib/image_pipe/transform.ex \
        lib/image_pipe/transform/plan_executor.ex lib/image_pipe/plan/key_data.ex \
        test/image_pipe/architecture_boundary_test.exs
git commit -m "feat(transform): add NormalizeColorProfile operation (scp)"
```

---

## Task 2: Parser emits `NormalizeColorProfile` for `scp`

**Prerequisite:** Task 1 must be complete — the test references `ImagePipe.Plan.Operation.NormalizeColorProfile` and won't compile otherwise.

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex`, `lib/image_pipe/parser/imgproxy/pipeline_request.ex`, `lib/image_pipe/parser/imgproxy/options.ex`, `lib/image_pipe/parser/imgproxy/plan_builder.ex`, `lib/image_pipe/parser/imgproxy.ex`
- Test: `test/parser/imgproxy_test.exs`

- [ ] **Step 1: Extend the helper, then write the failing parser test**

First extend the test's operation-name mapping. The parser test maps operation structs to atoms with `defp operation_name/1` clauses (`test/parser/imgproxy_test.exs:1683+`, ending at `:saturation`). Add a clause:

```elixir
  defp operation_name(%Operation.NormalizeColorProfile{}), do: :normalize_color_profile
```

Confirm `@no_auto_rotate_opts` is `[imgproxy: [auto_rotate: false]]` (and does **not** set `strip_color_profile`), so scp stays default-on below.

Then add the test (reuse aliases `Plan`, `Pipeline`, `Imgproxy`, `Operation`, `operation_names/1`, `@no_auto_rotate_opts`):

```elixir
  test "strip_color_profile emits NormalizeColorProfile after geometry, before effects" do
    # default config: scp on
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: ops}]}} =
             Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg"), @no_auto_rotate_opts)
    assert :normalize_color_profile in operation_names(ops)

    # explicit scp:0 disables
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: ops0}]}} =
             Imgproxy.parse(conn(:get, "/_/scp:0/plain/images/cat.jpg"), @no_auto_rotate_opts)
    refute :normalize_color_profile in operation_names(ops0)

    # config default off, URL scp:1 re-enables
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: ops1}]}} =
             Imgproxy.parse(
               conn(:get, "/_/scp:1/plain/images/cat.jpg"),
               imgproxy: [strip_color_profile: false]
             )
    assert :normalize_color_profile in operation_names(ops1)

    # position: after resize, before blur
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: pos_ops}]}} =
             Imgproxy.parse(
               conn(:get, "/_/w:10/bl:2/plain/images/cat.jpg"),
               @no_auto_rotate_opts
             )

    names = operation_names(pos_ops)
    assert Enum.find_index(names, &(&1 == :resize)) <
             Enum.find_index(names, &(&1 == :normalize_color_profile))
    assert Enum.find_index(names, &(&1 == :normalize_color_profile)) <
             Enum.find_index(names, &(&1 == :blur))
  end
```

If `@no_auto_rotate_opts` is `[imgproxy: [auto_rotate: false]]`, extend it to also disable scp where the test needs only resize/effect ordering — but here we WANT scp on, so `@no_auto_rotate_opts` (auto_rotate off, scp default on) is correct. Confirm `@no_auto_rotate_opts` does not set `strip_color_profile`.

- [ ] **Step 2: Run it to verify failure**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: FAIL — scp not parsed; no `:normalize_color_profile` operation.

- [ ] **Step 3: Add `scp` parsing to the grammar**

In `lib/image_pipe/parser/imgproxy/option_grammar.ex`, add a `parse_special_option/3` clause immediately after the existing `flip` clause (currently around line 397):

```elixir
  defp parse_special_option(name, args, segment)
       when name in ["strip_color_profile", "scp"] do
    parse_strip_color_profile(args, segment)
  end
```

Add the helper (near `parse_auto_rotate/2`):

```elixir
  defp parse_strip_color_profile([], _segment),
    do: {:ok, [strip_color_profile: true]}

  defp parse_strip_color_profile([value], _segment) when value != "" do
    with {:ok, value?} <- parse_boolean(value) do
      {:ok, [strip_color_profile: value?]}
    end
  end

  defp parse_strip_color_profile(_args, segment),
    do: {:error, {:invalid_option_segment, segment}}
```

(Special options return `{:pipeline, assignments}` via `parse_non_preset_option/3`, so no `@option_specs`/scope change is needed.)

- [ ] **Step 4: Add fields to `PipelineRequest`**

In `lib/image_pipe/parser/imgproxy/pipeline_request.ex`, add to the `@type t()` (e.g. after `auto_rotate_requested`):

```elixir
          auto_rotate_requested: boolean(),
          strip_color_profile: boolean(),
          strip_color_profile_requested: boolean(),
```

And to `defstruct` (matching defaults — both `false`):

```elixir
            auto_rotate_requested: false,
            strip_color_profile: false,
            strip_color_profile_requested: false,
```

- [ ] **Step 5: Apply the scp assignment in `options.ex`**

In `lib/image_pipe/parser/imgproxy/options.ex`, inside `update_current_pipeline/2`'s `Enum.reduce` (before the catch-all `assignment, pipeline -> struct!(...)`):

```elixir
        {:strip_color_profile, value}, pipeline ->
          %{pipeline | strip_color_profile: value, strip_color_profile_requested: true}
```

- [ ] **Step 6: Resolve the scp default request-wide in `apply_request_defaults/2`**

Replace `apply_request_defaults/2` body so it resolves scp alongside auto_rotate (mirroring the auto_rotate helpers):

```elixir
  defp apply_request_defaults(%{pipelines: pipelines} = options, defaults) do
    auto_rotate? = effective_auto_rotate(pipelines, Keyword.get(defaults, :auto_rotate, false))

    scp? =
      effective_strip_color_profile(pipelines, Keyword.get(defaults, :strip_color_profile, true))

    pipelines =
      pipelines
      |> Enum.map(&consume_auto_rotate_request/1)
      |> Enum.map(&consume_strip_color_profile_request/1)
      |> apply_auto_rotate_to_first_pipeline(auto_rotate?)
      |> apply_strip_color_profile_to_first_pipeline(scp?)
      |> reject_empty_pipelines()

    %{options | pipelines: pipelines}
  end
```

Add the helpers (beside the auto_rotate ones):

```elixir
  defp effective_strip_color_profile(pipelines, default) do
    Enum.reduce(pipelines, default, fn
      %PipelineRequest{strip_color_profile_requested: true, strip_color_profile: value}, _acc ->
        value

      %PipelineRequest{}, acc ->
        acc
    end)
  end

  defp consume_strip_color_profile_request(%PipelineRequest{} = pipeline),
    do: %{pipeline | strip_color_profile: false, strip_color_profile_requested: false}

  defp apply_strip_color_profile_to_first_pipeline(pipelines, false), do: pipelines

  defp apply_strip_color_profile_to_first_pipeline([first | rest], true),
    do: [%{first | strip_color_profile: true} | rest]
```

- [ ] **Step 7: Emit the operation in `plan_builder.ex`**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, add a clause function. `Operation.normalize_color_profile/0` returns `{:ok, struct}` (like every constructor), so unwrap it:

```elixir
  defp color_profile_operations(%PipelineRequest{strip_color_profile: true}) do
    with {:ok, operation} <- Operation.normalize_color_profile() do
      {:ok, [operation]}
    end
  end

  defp color_profile_operations(%PipelineRequest{}), do: {:ok, []}
```

In `plan_geometry/1`, add it to the `with` and insert it **between resize and effects**:

```elixir
  defp plan_geometry(%PipelineRequest{} = request) do
    with {:ok, orientation_operations} <- orientation_operations(request),
         {:ok, crop_operations} <- crop_operations(request),
         {:ok, resize_operations} <- resize_operations(request),
         {:ok, color_profile_operations} <- color_profile_operations(request),
         {:ok, effect_operations} <- effect_operations(request),
         {:ok, canvas_operations} <- canvas_operations(request),
         {:ok, padding_operations} <- padding_operations(request),
         {:ok, background_operations} <- background_operations(request) do
      {:ok,
       orientation_operations ++
         crop_operations ++
         resize_operations ++
         color_profile_operations ++
         effect_operations ++
         canvas_operations ++
         padding_operations ++
         background_operations}
    end
  end
```

- [ ] **Step 8: Add the config option + request default in `imgproxy.ex`**

In `@imgproxy_schema`, add after `auto_rotate`:

```elixir
                     auto_rotate: [
                       type: :boolean,
                       default: true
                     ],
                     strip_metadata: [type: :boolean, default: true],
                     keep_copyright: [type: :boolean, default: true],
                     strip_color_profile: [type: :boolean, default: true]
```

Update `request_defaults/1`:

```elixir
  defp request_defaults(imgproxy_opts) do
    [
      auto_rotate: Keyword.get(imgproxy_opts, :auto_rotate, true),
      strip_metadata: Keyword.get(imgproxy_opts, :strip_metadata, true),
      keep_copyright: Keyword.get(imgproxy_opts, :keep_copyright, true),
      strip_color_profile: Keyword.get(imgproxy_opts, :strip_color_profile, true)
    ]
  end
```

- [ ] **Step 9: Run the parser test**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/ lib/image_pipe/parser/imgproxy.ex test/parser/imgproxy_test.exs
git commit -m "feat(parser): map imgproxy scp to NormalizeColorProfile with parser-owned default"
```

---

## Task 3: `Plan.Output` `sm`/`kcr` fields + parser mapping & normalization

> **R1 (post-review) addendum:** also add `strip_color_profile` to `Plan.Output`
> (default `true`) — the encoder (Task 5) needs it to drop the profile header.
> In `apply_request_defaults/2`, set `output.strip_color_profile` from the same
> resolved `scp?` value that drives op emission (Task 2), so they stay
> consistent; and add `strip_color_profile: nil` to `@default_output` so the key
> exists. Do NOT add `strip_color_profile` to the cache key's `output_plan_data`
> (Task 4) — it is already keyed via the `NormalizeColorProfile` op's `KeyData`.
> See the design spec's "Metadata policy" / "Output encode path" sections.

**Files:**
- Modify: `lib/image_pipe/plan/output.ex`, `lib/image_pipe/parser/imgproxy/option_grammar.ex`, `lib/image_pipe/parser/imgproxy/parsed_request.ex`, `lib/image_pipe/parser/imgproxy/options.ex`, `lib/image_pipe/parser/imgproxy/plan_builder.ex`
- Test: `test/parser/imgproxy_test.exs`

- [ ] **Step 1: Write the failing parser test**

Add to `test/parser/imgproxy_test.exs` (alias `ImagePipe.Plan.Output` if not present):

```elixir
  test "strip_metadata/keep_copyright map to Plan.Output with kcr normalization" do
    # defaults: both on
    assert {:ok, %Plan{output: %Output{strip_metadata: true, keep_copyright: true}}} =
             Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg"), [])

    # sm:0 forces keep_copyright to false (normalization)
    assert {:ok, %Plan{output: %Output{strip_metadata: false, keep_copyright: false}}} =
             Imgproxy.parse(conn(:get, "/_/sm:0/kcr:1/plain/images/cat.jpg"), [])

    # kcr:0 with stripping on
    assert {:ok, %Plan{output: %Output{strip_metadata: true, keep_copyright: false}}} =
             Imgproxy.parse(conn(:get, "/_/kcr:0/plain/images/cat.jpg"), [])

    # config default off, URL re-enables
    assert {:ok, %Plan{output: %Output{strip_metadata: true}}} =
             Imgproxy.parse(
               conn(:get, "/_/sm:1/plain/images/cat.jpg"),
               imgproxy: [strip_metadata: false]
             )
  end
```

- [ ] **Step 2: Run it to verify failure**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: FAIL — `Output` has no `strip_metadata`/`keep_copyright`.

- [ ] **Step 3: Add fields to `Plan.Output`**

Replace the struct/typespec in `lib/image_pipe/plan/output.ex`:

```elixir
  @enforce_keys [:mode]
  defstruct mode: :automatic,
            quality: :default,
            format_qualities: %{},
            strip_metadata: true,
            keep_copyright: true

  @type format :: :avif | :webp | :jpeg | :png
  @type quality :: :default | {:quality, 1..100}
  @type t :: %__MODULE__{
          mode: :automatic | {:explicit, format()},
          quality: quality(),
          format_qualities: %{optional(format()) => quality()},
          strip_metadata: boolean(),
          keep_copyright: boolean()
        }
```

- [ ] **Step 4: Add `sm`/`kcr` to the grammar**

In `option_grammar.ex` `@option_specs`, add:

```elixir
    "strip_metadata" => {:strip_metadata, [:strip_metadata]},
    "sm" => {:strip_metadata, [:strip_metadata]},
    "keep_copyright" => {:keep_copyright, [:keep_copyright]},
    "kcr" => {:keep_copyright, [:keep_copyright]},
```

Add to the `parse_known_option/4` guard list (the clause that calls `parse_exact_fields`):

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
              :keep_copyright
            ] do
    parse_exact_fields(fields, args, segment)
  end
```

Add `parse_field/2` clauses (beside `parse_field(:enlarge, ...)`):

```elixir
  defp parse_field(:strip_metadata, value), do: parse_boolean(value)
  defp parse_field(:keep_copyright, value), do: parse_boolean(value)
```

**Extend the existing** `scoped_assignments/2` clause (currently `when kind in [:format, :quality, :format_quality]`, around line 105) by adding the two new kinds to its `when` guard — do not add a second clause:

```elixir
  defp scoped_assignments(kind, assignments)
       when kind in [:format, :quality, :format_quality, :strip_metadata, :keep_copyright],
       do: {:output, assignments}
```

- [ ] **Step 5: Add fields to the parsed-output map**

In `lib/image_pipe/parser/imgproxy/parsed_request.ex`, update `@default_output` and the `output_request()` type to carry the (initially unset) values:

```elixir
  @default_output %{
    format: nil,
    quality: :default,
    format_qualities: %{},
    strip_metadata: nil,
    keep_copyright: nil
  }
```

```elixir
  @type output_request() :: %{
          required(:format) => output_format() | nil,
          required(:quality) => quality(),
          required(:format_qualities) => %{optional(output_format()) => quality()},
          required(:strip_metadata) => boolean() | nil,
          required(:keep_copyright) => boolean() | nil
        }
```

(`update_output/2` already merges arbitrary known output keys via `merge_request_map`, so no change there.)

- [ ] **Step 6: Resolve sm/kcr defaults + normalize in `options.ex`**

**This replaces the `apply_request_defaults/2` you wrote in Task 2 Step 6** — it is the final form, a superset that resolves `auto_rotate`, `scp`, **and** the output `sm`/`kcr` defaults. Confirm the scp logic from Task 2 is preserved verbatim below (add `output:` to the destructure and the return):

```elixir
  defp apply_request_defaults(%{pipelines: pipelines, output: output} = options, defaults) do
    auto_rotate? = effective_auto_rotate(pipelines, Keyword.get(defaults, :auto_rotate, false))

    scp? =
      effective_strip_color_profile(pipelines, Keyword.get(defaults, :strip_color_profile, true))

    pipelines =
      pipelines
      |> Enum.map(&consume_auto_rotate_request/1)
      |> Enum.map(&consume_strip_color_profile_request/1)
      |> apply_auto_rotate_to_first_pipeline(auto_rotate?)
      |> apply_strip_color_profile_to_first_pipeline(scp?)
      |> reject_empty_pipelines()

    %{options | pipelines: pipelines, output: resolve_metadata_defaults(output, defaults)}
  end

  defp resolve_metadata_defaults(output, defaults) do
    strip = resolve_bool(output.strip_metadata, Keyword.get(defaults, :strip_metadata, true))
    keep = resolve_bool(output.keep_copyright, Keyword.get(defaults, :keep_copyright, true))
    %{output | strip_metadata: strip, keep_copyright: strip and keep}
  end

  defp resolve_bool(nil, default), do: default
  defp resolve_bool(value, _default) when is_boolean(value), do: value
```

- [ ] **Step 7: Read the fields in `plan_builder.ex` `output_plan/1`**

In both `output_plan/1` clauses (`:automatic` and `{:explicit, format}`), add the two fields to the `%Output{}`:

```elixir
  defp output_plan(%{format: nil} = request) do
    {:ok,
     %Output{
       mode: :automatic,
       quality: request.quality,
       format_qualities: request.format_qualities,
       strip_metadata: request.strip_metadata,
       keep_copyright: request.keep_copyright
     }}
  end
```

```elixir
  defp output_plan(%{format: format} = request) do
    case Format.output_format?(format) do
      true ->
        {:ok,
         %Output{
           mode: {:explicit, format},
           quality: request.quality,
           format_qualities: request.format_qualities,
           strip_metadata: request.strip_metadata,
           keep_copyright: request.keep_copyright
         }}

      false ->
        {:error, {:unsupported_output_format, format}}
    end
  end
```

(Leave the `%{format: :best}` clause unchanged.)

- [ ] **Step 8: Run the parser test**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add lib/image_pipe/plan/output.ex lib/image_pipe/parser/imgproxy/ test/parser/imgproxy_test.exs
git commit -m "feat(parser): map imgproxy sm/kcr to Plan.Output with normalization"
```

---

## Task 4: Cache key includes `sm`/`kcr`

**Files:**
- Modify: `lib/image_pipe/cache/key.ex`
- Test: `test/parser/imgproxy_test.exs` (or the cache-key test module if one exists; this asserts via parsed plans + `ImagePipe.Cache.Key`)

- [ ] **Step 1: Write the failing cache-key distinctness test**

Add to `test/parser/imgproxy_test.exs` (alias `ImagePipe.Cache.Key`). **Verified signature:** `Cache.Key.build(conn, %Plan{} = plan, source_identity, opts \\ [])` — conn first, plan second, then a `source_identity` term. A constant binary `source_identity` is fine here: we only vary `sm`/`kcr`/`scp`, so everything else in the key stays constant.

```elixir
  test "sm/kcr/scp produce distinct cache keys" do
    key = fn path ->
      {:ok, plan} = Imgproxy.parse(conn(:get, path), [])
      ImagePipe.Cache.Key.build(conn(:get, path), plan, "source-identity")
    end

    base = key.("/_/sm:1/kcr:1/scp:1/plain/images/cat.jpg")

    refute base == key.("/_/sm:0/kcr:1/scp:1/plain/images/cat.jpg")
    refute base == key.("/_/sm:1/kcr:0/scp:1/plain/images/cat.jpg")
    refute base == key.("/_/sm:1/kcr:1/scp:0/plain/images/cat.jpg")
  end
```

(`scp` distinctness already works via Task 1's KeyData; this test also guards it. If `Cache.Key.build/3,4` returns `{:ok, key}` rather than a bare key, unwrap accordingly — read `lib/image_pipe/cache/key.ex:30`.)

- [ ] **Step 2: Run it to verify failure**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: FAIL on the `sm:0` and `kcr:0` cases (keys equal) — `output_plan_data` ignores sm/kcr. (The `scp:0` case should already pass.)

- [ ] **Step 3: Add sm/kcr to `output_plan_data/2`**

In `lib/image_pipe/cache/key.ex`, add the two fields to **both** clauses:

```elixir
  defp output_plan_data(%Output{mode: :automatic} = output, opts) do
    {:ok,
     [
       mode: :automatic,
       auto: [
         avif: Keyword.get(opts, :auto_avif, true),
         webp: Keyword.get(opts, :auto_webp, true)
       ],
       quality: output.quality,
       format_qualities: output.format_qualities,
       strip_metadata: output.strip_metadata,
       keep_copyright: output.keep_copyright
     ]}
  end

  defp output_plan_data(%Output{mode: {:explicit, format}} = output, _opts) do
    {:ok,
     [
       mode: :explicit,
       format: format,
       quality: output.quality,
       format_qualities: output.format_qualities,
       strip_metadata: output.strip_metadata,
       keep_copyright: output.keep_copyright
     ]}
  end
```

- [ ] **Step 4: Run the cache-key test**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/key.ex test/parser/imgproxy_test.exs
git commit -m "feat(cache): include strip_metadata/keep_copyright in output cache key"
```

---

## Task 5: Thread `sm`/`kcr`/`scp` to the encoder and strip metadata (R1)

> **R1 (post-review) — this task is rewritten.** The authoritative design is the
> spec's "Output encode path: sm/kcr/scp metadata via Vix mutate (after a safe
> realize)". Key differences from the steps below:
> - Thread **three** flags — `strip_metadata`, `keep_copyright`,
>   **`strip_color_profile`** — through `Policy` and `Resolved` (add all three to
>   `@enforce_keys` and `Policy.resolved/2`).
> - `Encoder.stream_output/3` must **realize once via `Vix.Vips.Image.copy_memory/1`
>   before any `mutate`**, and only when stripping is needed
>   (`strip_metadata or strip_color_profile`). On `copy_memory` `{:error, reason}`
>   return `{:error, {:decode, reason}}` (→ 415), NOT a crash.
> - The strip step handles `scp` too: drop `icc-profile-data` when
>   `strip_color_profile` is true; the `kcr` branch restores the ICC profile only
>   when `scp` is **off**. Exact logic is in the spec's `finalize`/`strip`
>   pseudocode.
> - Required code comments: the `copy_memory`-before-`mutate` rationale, the
>   `"xmp-dataa"` typo, and `minimize_metadata`'s ICC over-strip.
> The dispatched implementer prompt will carry the full R1 code. The steps below
> are the pre-R1 version, retained for context only.

**Files:**
- Modify: `lib/image_pipe/output/policy.ex`, `lib/image_pipe/output/resolved.ex`, `lib/image_pipe/output/encoder.ex`
- Test: covered end-to-end by Task 6 (`sm`/`kcr`) and Task 7 (`scp`) wire tests, including a corrupt-source test asserting 415 (no producer crash).

- [ ] **Step 1: Add fields to `Output.Resolved`**

In `lib/image_pipe/output/resolved.ex`:

```elixir
  @enforce_keys [:format, :quality, :response_headers, :strip_metadata, :keep_copyright]
  defstruct @enforce_keys

  @type format :: ImagePipe.Format.output_format()
  @type quality :: :default | {:quality, 1..100}
  @type t :: %__MODULE__{
          format: format(),
          quality: quality(),
          response_headers: [{String.t(), String.t()}],
          strip_metadata: boolean(),
          keep_copyright: boolean()
        }
```

- [ ] **Step 2: Thread through `Output.Policy`**

In `lib/image_pipe/output/policy.ex`: add `:strip_metadata, :keep_copyright` to `@enforce_keys`, the `@type t()`, and **both** `from_output_plan/3` clauses (copy from `output`), then set them in `resolved/2`:

```elixir
  @enforce_keys [
    :mode,
    :modern_candidates,
    :headers,
    :quality,
    :format_qualities,
    :strip_metadata,
    :keep_copyright
  ]
```

In each `from_output_plan/3` clause add:

```elixir
      strip_metadata: output.strip_metadata,
      keep_copyright: output.keep_copyright
```

In `resolved/2`:

```elixir
  defp resolved(%__MODULE__{} = policy, format) do
    %Resolved{
      format: format,
      quality: effective_quality(policy, format),
      response_headers: policy.headers,
      strip_metadata: policy.strip_metadata,
      keep_copyright: policy.keep_copyright
    }
  end
```

- [ ] **Step 3: Apply stripping in `Output.Encoder`**

Rewrite `lib/image_pipe/output/encoder.ex` `stream_output/3` to finalize before streaming:

```elixir
  def stream_output(%Vix.Vips.Image{} = image, %Resolved{} = resolved_output, opts) do
    with {:ok, mime_type, suffix} <- output_format(resolved_output) do
      image_module = Keyword.get(opts, :image_module, Image)
      finalized = strip_metadata(image, resolved_output)
      stream = image_module.stream!(finalized, output_options(suffix, resolved_output))
      {:ok, stream, mime_type}
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end

  # Metadata stripping uses explicit libvips header field names via Vix mutate.
  # We deliberately avoid:
  #   * the libvips `strip` write flag — it also removes the ICC profile, but
  #     `scp` (NormalizeColorProfile) owns profile handling independently;
  #   * `Image.remove_metadata(img, :xmp)` — `image` v0.67 maps `:xmp` to
  #     "xmp-dataa" (a typo), so it silently leaves XMP in;
  #   * default `remove_metadata`/`minimize_metadata` for the no-kcr path — they
  #     enumerate and remove ALL header fields, including `icc-profile-data`.
  defp strip_metadata(image, %Resolved{strip_metadata: false}), do: image

  defp strip_metadata(image, %Resolved{keep_copyright: true} = _resolved) do
    icc = header_value(image, "icc-profile-data")

    image
    |> Image.minimize_metadata!(keep: [:copyright, :artist])
    |> restore_icc(icc)
  end

  defp strip_metadata(image, %Resolved{}) do
    {:ok, image} =
      Vix.Vips.Image.mutate(image, fn mut ->
        Enum.each(["exif-data", "xmp-data", "iptc-data"], &Vix.Vips.MutableImage.remove(mut, &1))
        :ok
      end)

    image
  end

  defp header_value(image, field) do
    case Vix.Vips.Image.header_value(image, field) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp restore_icc(image, nil), do: image

  defp restore_icc(image, icc) do
    {:ok, image} =
      Vix.Vips.Image.mutate(image, fn mut ->
        Vix.Vips.MutableImage.set(mut, "icc-profile-data", :VipsBlob, icc)
        :ok
      end)

    image
  end
```

**Verified:** `Vix.Vips.Image.mutate!/2` does **not** exist — only `mutate/2`, which returns `{:ok, image}`; the callback must return `:ok` (or `{:ok, term}`). `Image.minimize_metadata!/2` is the real bang variant.

**ICC round-trip caveat (validate during Task 6/7 TDD):** `header_value/2` returns the blob as an Erlang term; re-setting it via `MutableImage.set(.., :VipsBlob, value)` may not round-trip for every libvips build. If the `scp:0 + kcr:1 + profiled source` wire case shows the profile lost, switch the backup/restore to `Vix.Vips.Image.header_value_as_string/2` + base64 decode, or capture/re-add EXIF copyright fields directly without `minimize_metadata!`. This path is exercised only by the non-default `scp:0 + kcr:1` combination.

- [ ] **Step 4: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/resolved.ex lib/image_pipe/output/policy.ex lib/image_pipe/output/encoder.ex
git commit -m "feat(output): apply strip_metadata/keep_copyright at encode (Vix mutate)"
```

---

## Task 6: Wire tests for `sm`/`kcr` (metadata fixtures)

**Files:**
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Add a metadata-bearing origin image generator + helper**

In `test/image_pipe/imgproxy_wire_conformance_test.exs`, add an origin Plug that emits a JPEG carrying EXIF (incl. copyright/artist), XMP, and IPTC header fields (mirror `ExifOrientationOriginImage`):

```elixir
  defmodule MetadataOriginImage do
    @moduledoc false

    def call(conn, _opts) do
      {:ok, img} =
        40
        |> Image.new!(40, color: :red)
        |> Vix.Vips.Image.mutate(fn m ->
          :ok = Vix.Vips.MutableImage.set(m, "exif-ifd0-Copyright", :gchararray, "(c) ACME")
          :ok = Vix.Vips.MutableImage.set(m, "exif-ifd0-Artist", :gchararray, "ACME")
          :ok = Vix.Vips.MutableImage.set(m, "exif-ifd0-ImageDescription", :gchararray, "secret")
          :ok = Vix.Vips.MutableImage.set(m, "xmp-data", :VipsBlob, "<x:xmpmeta/>")
          :ok = Vix.Vips.MutableImage.set(m, "iptc-data", :VipsBlob, "iptc")
          :ok
        end)

      body = Image.write!(img, :memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defp metadata_origin_opts(overrides \\ []) do
    Keyword.merge(
      [
        parser: ImagePipe.Parser.Imgproxy,
        sources: [
          path:
            {RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: MetadataOriginImage]}
        ]
      ],
      overrides
    )
  end

  defp response_fields(conn) do
    {:ok, img} = Image.open(conn.resp_body)
    {:ok, names} = Vix.Vips.Image.header_field_names(img)
    {img, names}
  end
```

**Note (validate during TDD):** raw EXIF/XMP/IPTC set on a synthetic image must survive the JPEG round-trip for these assertions to be meaningful. If libvips drops them on `write!`, first assert presence on the **non-stripped** (`sm:0`) response; if even `sm:0` lacks them, switch the fixture to a committed real JPEG that carries the metadata, or adjust which fields you assert on. Resolve this before writing Step 2's assertions.

- [ ] **Step 2: Write the failing wire tests**

```elixir
  test "imgproxy default strips EXIF/XMP/IPTC; sm:0 keeps them" do
    stripped =
      "/_/scp:0/f:jpeg/plain/images/meta.jpg"
      |> call_imgproxy(metadata_origin_opts())

    assert stripped.status == 200
    {_img, names} = response_fields(stripped)
    refute "exif-data" in names
    refute "xmp-data" in names
    refute "iptc-data" in names

    kept =
      "/_/sm:0/scp:0/f:jpeg/plain/images/meta.jpg"
      |> call_imgproxy(metadata_origin_opts())

    {_img2, kept_names} = response_fields(kept)
    assert "exif-data" in kept_names
  end

  test "imgproxy kcr:1 keeps EXIF copyright while stripping the rest" do
    conn =
      "/_/sm:1/kcr:1/scp:0/f:jpeg/plain/images/meta.jpg"
      |> call_imgproxy(metadata_origin_opts())

    assert conn.status == 200
    {img, _names} = response_fields(conn)
    {:ok, exif} = Image.exif(img)
    assert exif[:copyright] == "(c) ACME"
  end
```

- [ ] **Step 3: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: FAIL initially if the source route name differs — register the `images/meta.jpg` path the same way the suite registers `images/oriented.jpg` (reuse the existing source-path convention in this file). Then FAIL on assertions until Tasks 3 & 5 behavior is exercised (they are already merged, so failures here indicate fixture/round-trip issues to resolve per Step 1's note).

- [ ] **Step 4: Make tests pass**

Resolve fixture round-trip per Step 1's note (most likely: assert on the fields that survive JPEG encode for your libvips build, or use a committed fixture). No production code change should be needed if Tasks 3 & 5 are correct; if `Image.exif/1` returns no copyright, verify the encoder's `kcr` branch ran (`minimize_metadata!(keep: [:copyright, :artist])`).

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs && mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(imgproxy): wire tests for sm/kcr metadata stripping"
```

---

## Task 7: Wire test for `scp` (wide-gamut fixture)

**Files:**
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Add a wide-gamut origin generator**

```elixir
  defmodule WideGamutOriginImage do
    @moduledoc false

    def call(conn, _opts) do
      # Start from sRGB pixels, attach a non-sRGB profile so scp has work to do.
      {:ok, p3} = Image.to_colorspace(Image.new!(40, 40, color: [200, 50, 50]), :p3, [])
      body = Image.write!(p3, :memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end
```

**Validate during TDD:** confirm `Image.to_colorspace(img, :p3, [])` produces a PNG whose decoded form carries `icc-profile-data` (assert on the `scp:0` response below). If `:p3` embedding doesn't round-trip in your libvips build, substitute a committed wide-gamut fixture (Display-P3 PNG/JPEG).

- [ ] **Step 2: Write the failing test**

```elixir
  test "imgproxy scp:1 outputs sRGB with no embedded profile; scp:0 keeps it" do
    dropped =
      "/_/scp:1/f:png/plain/images/wide.png"
      |> call_imgproxy(wide_gamut_origin_opts())

    assert dropped.status == 200
    {_img, names} = response_fields(dropped)
    refute "icc-profile-data" in names

    kept =
      "/_/scp:0/f:png/plain/images/wide.png"
      |> call_imgproxy(wide_gamut_origin_opts())

    {_img2, kept_names} = response_fields(kept)
    assert "icc-profile-data" in kept_names
  end
```

Add `wide_gamut_origin_opts/0` mirroring `metadata_origin_opts/1` with `WideGamutOriginImage`, and register the `images/wide.png` source path.

- [ ] **Step 3: Run to verify failure, then pass**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: initially FAIL (resolve fixture round-trip per Step 1); PASS once the wide-gamut profile round-trips. No production change needed if Tasks 1–2 are correct.

- [ ] **Step 4: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(imgproxy): wire test for scp color-profile normalization"
```

> **On the spec's pixel-ordering test:** the spec proposed a `scp:1 + tone effect`
> wire test comparing pixels against `scp:0` with a tolerance. The *structural*
> guarantee (conversion runs after resize, before the effect chain) is asserted
> deterministically in Task 2 Step 1 (`resize < normalize_color_profile < blur`),
> which is robust. A pixel-distance comparison across libvips resampling is
> brittle and adds little over the structural assertion + the profile-presence
> assertions here, so it is intentionally omitted. Add it only if a regression
> motivates it.

---

## Task 8: Demo controls + URL state

**Files:**
- Modify: `demo/src/processing-path.ts`, `demo/src/demo-url-state.ts`, `demo/src/App.svelte`

- [ ] **Step 1: Add state fields + defaults**

In `demo/src/processing-path.ts` `DemoState`, add (near `autoRotateEnabled`):

```typescript
  stripMetadata: boolean;
  keepCopyright: boolean;
  stripColorProfile: boolean;
```

In `defaultDemoState`, add (defaults true, matching the backend):

```typescript
  stripMetadata: true,
  keepCopyright: true,
  stripColorProfile: true,
```

- [ ] **Step 2: Emit URL segments (canonical)**

In `optionSegments()` (the function that builds segments in `processing-path.ts`), add — emitting only non-default values, and **skipping `kcr` when `stripMetadata` is false** so the URL matches the planner normalization:

```typescript
  if (!currentState.stripMetadata) {
    segments.push("sm:0");
  } else if (!currentState.keepCopyright) {
    segments.push("kcr:0");
  }

  if (!currentState.stripColorProfile) {
    segments.push("scp:0");
  }
```

- [ ] **Step 3: Parse URL segments**

In `demo/src/demo-url-state.ts`, add cases to `applyOptionSegment` and parse helpers (mirroring `parseAutoRotate`), accepting `1`/`t`/`true` and `0`/`f`/`false`:

```typescript
    case "sm":
      return parseBoolOption(currentState, args, "stripMetadata");
    case "kcr":
      return parseBoolOption(currentState, args, "keepCopyright");
    case "scp":
      return parseBoolOption(currentState, args, "stripColorProfile");
```

```typescript
function parseBoolOption(
  currentState: DemoState,
  args: string[],
  key: "stripMetadata" | "keepCopyright" | "stripColorProfile",
): DemoState | null {
  if (args.length !== 1) return null;
  const v = args[0];
  if (["1", "t", "true"].includes(v)) return { ...currentState, [key]: true };
  if (["0", "f", "false"].includes(v)) return { ...currentState, [key]: false };
  return null;
}
```

On parse, normalize: if `stripMetadata` is false, force `keepCopyright` false (mirror the backend). Add to the relevant post-parse normalization, or in `parseBoolOption` when key is `stripMetadata` and value false also set `keepCopyright: false`.

- [ ] **Step 4: Add UI controls**

In `demo/src/App.svelte`, add a "Metadata & Color" collapsible section (mirror the Orientation/Effects switch pattern) with three switches bound to `state.stripMetadata`, `state.keepCopyright`, `state.stripColorProfile`. Disable the `keepCopyright` switch when `!state.stripMetadata`:

```svelte
            <label class="switch-field">
              <Switch.Root class="switch-root" bind:checked={state.keepCopyright} disabled={!state.stripMetadata}>
                <Switch.Thumb class="switch-thumb" />
              </Switch.Root>
              <span>Keep copyright when stripping</span>
            </label>
```

- [ ] **Step 5: Run the demo verify suite**

Run: `mise run precommit:demo`
Expected: PASS (Elixir gate + `mix demo.verify`). Fix any demo URL-state round-trip test failures.

- [ ] **Step 6: Commit**

```bash
git add demo/src/processing-path.ts demo/src/demo-url-state.ts demo/src/App.svelte
git commit -m "feat(demo): add metadata & color-profile controls"
```

---

## Task 9: Documentation

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`, `docs/transform_operations.md`

- [ ] **Step 1: Update the support matrix**

In `docs/imgproxy_support_matrix.md`:
- Change `strip_metadata` (`sm`), `keep_copyright` (`kcr`), `strip_color_profile` (`scp`) rows from Missing to **Supported**; note default-on and that the imgproxy config (`strip_metadata`/`keep_copyright`/`strip_color_profile`, default true) owns the defaults.
- Change the config rows `IMGPROXY_STRIP_METADATA`, `IMGPROXY_KEEP_COPYRIGHT`, `IMGPROXY_STRIP_COLOR_PROFILE` from ⭕ to ✅ (URL-only/config as appropriate).
- Document the two deliberate divergences: `keep_copyright` keeps **EXIF copyright/artist only** (XMP/IPTC stripped); no full import/export color management yet (link #124).

- [ ] **Step 2: Update transform operations doc**

In `docs/transform_operations.md`, add a "Color profile" subsection documenting `NormalizeColorProfile` (semantic + executable), its sRGB-convert-and-drop behavior, and its fixed position: after geometry, immediately before the effect chain.

- [ ] **Step 3: Commit**

```bash
git add docs/imgproxy_support_matrix.md docs/transform_operations.md
git commit -m "docs: mark imgproxy sm/kcr/scp supported; document NormalizeColorProfile"
```

---

## Final verification

- [ ] **Run the full gate**

Run: `mise run precommit` (format check, `compile --warnings-as-errors`, `credo --strict`, `mix test`), then `mise run precommit:demo`.
Expected: all pass. Fix any credo/format issues (e.g. alias ordering) inline.

- [ ] **Confirm spec divergences hold:** default request strips EXIF/XMP/GPS and normalizes to sRGB; `sm:0`/`scp:0`/`kcr` behave per the wire tests; cache keys distinct.

---

## Notes for the implementer

- **TDD seams:** this codebase tests at boundaries (parser→plan, wire-level `ImagePipe.call/2` decoding the body, cache key). Do **not** hand-build `Transform.State`, `Plan.Pipeline`, or operation structs in tests to assert internals — it violates the repo's test guidelines.
- **Validate during TDD** (flagged inline): whether synthetic EXIF/XMP/IPTC/ICC survive the encode round-trip (Tasks 6–7), and the ICC backup/restore round-trip in the encoder `kcr` branch (Task 5). Resolve against the real API before finalizing assertions. (`mutate/2` vs `mutate!/2` is already resolved — only `mutate/2` exists.)
- **`Cache.Key.build/4`** signature in Task 4 must match the real function — read `lib/image_pipe/cache/key.ex` and adjust.
- Run focused tests with `mise exec -- mix test <file>` while iterating.
