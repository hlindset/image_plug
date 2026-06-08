# Output-Encoder Dimension Clamp (#150) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the realized final image exceeds the negotiated output encoder's hard dimension limit (WebP 16383, AVIF 16384), uniformly downscale it to fit before encoding — so encoding cannot fail — and emit a `[:output, :clamp]` telemetry signal.

**Architecture:** A post-hoc, product-neutral uniform downscale at the `ImagePipe.Output.*` boundary. `Output.Encoder.encoder_limit/1` holds the per-format dimension table; `Output.Clamp.clamp/3` does the generic downscale on a realized `Vix.Vips.Image` via the `image` library (no `Transform`/`Telemetry` dependency). The producer (`Request.SourceSession.Producer`, in the request boundary) wires them between format negotiation and `Encoder.stream_output`, and emits the telemetry one-shot when a clamp occurs. Cache key/ETag are unchanged (format already in the key; final dims derive from inputs).

**Tech Stack:** Elixir, `image`/Vix (libvips), `:telemetry`, ExUnit, `Boundary`. Run all tooling via `mise exec -- ...`.

**Spec:** `docs/superpowers/specs/2026-06-08-output-encoder-dimension-clamp-design.md` (read it; Resolved Decision D1 = dimension-only `clamp/3`, pixel/sqrt path deferred to #165).

---

## File Structure

- **Create** `lib/image_pipe/output/clamp.ex` — `ImagePipe.Output.Clamp`, the generic uniform downscale (`clamp/3`), product-neutral, no format/host knowledge.
- **Modify** `lib/image_pipe/output/encoder.ex` — add `encoder_limit/1` (per-format dimension table).
- **Modify** `lib/image_pipe/output.ex` — add `Clamp` to boundary `exports`.
- **Modify** `lib/image_pipe/request/source_session/producer.ex` — wire `encoder_limit` + `Clamp.clamp` + telemetry into `prepare_first_chunk/1`.
- **Modify** `lib/image_pipe/telemetry/logger.ex` — subscribe to + render the `[:output, :clamp]` one-shot at `:warning`.
- **Modify** `docs/telemetry.md` — document the `[:output, :clamp]` event.
- **Create** `test/image_pipe/output/clamp_test.exs` — direct unit tests for `Clamp.clamp/3`.
- **Modify** `test/image_pipe/imgproxy_wire_conformance_test.exs` — wire-level WebP/AVIF clamp tests + no-clamp control (real encode, decoded dims, telemetry).
- **Modify** `test/image_pipe/telemetry/logger_test.exs` — assert the clamp log line at `:warning`.

---

## Task 1: `Output.Encoder.encoder_limit/1` — per-format dimension table

**Files:**
- Modify: `lib/image_pipe/output/encoder.ex`
- Test: `test/image_pipe/output/clamp_test.exs` (created here; reused in Task 2)

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/output/clamp_test.exs` with the encoder-limit cases:

```elixir
defmodule ImagePipe.Output.ClampTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Encoder

  describe "encoder_limit/1" do
    test "returns the WebP and AVIF hard dimension limits" do
      assert Encoder.encoder_limit(:webp) == %{max_dimension: 16383}
      assert Encoder.encoder_limit(:avif) == %{max_dimension: 16384}
    end

    test "returns the documented JPEG limit and unbounded PNG" do
      assert Encoder.encoder_limit(:jpeg) == %{max_dimension: 65535}
      assert Encoder.encoder_limit(:png) == %{max_dimension: :infinity}
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output/clamp_test.exs`
Expected: FAIL — `function ImagePipe.Output.Encoder.encoder_limit/1 is undefined`.

- [ ] **Step 3: Add `encoder_limit/1` to the Encoder**

In `lib/image_pipe/output/encoder.ex`, add a public function near the top of the module (after the `alias` lines, before `stream_output/3`). The values are verified against `local/imgproxy-master/processing/fix_size.go:14-15`:

```elixir
@doc """
The output encoder's hard per-dimension limit for `format`, used by
`ImagePipe.Output.Clamp` to keep encoding from failing. `:infinity` means no
practical limit. Sourced from libvips encoder constraints (cf. imgproxy
`processing/fix_size.go`). #150 uses only `:max_dimension`; #165 will extend
the returned map with a `:max_pixels` budget when its caller makes that live.
"""
@spec encoder_limit(Format.format()) :: %{max_dimension: pos_integer() | :infinity}
def encoder_limit(:webp), do: %{max_dimension: 16_383}
def encoder_limit(:avif), do: %{max_dimension: 16_384}
def encoder_limit(:jpeg), do: %{max_dimension: 65_535}
def encoder_limit(:png), do: %{max_dimension: :infinity}
```

Note: the output-format type is `ImagePipe.Plan.Output.format` (`:avif | :webp | :jpeg | :png`, `plan/output.ex:19`). `Encoder` already `alias`es `ImagePipe.Format`; if `Format.format()` is not the right type alias, use `ImagePipe.Plan.Output.format()` in the `@spec` instead — pick whichever already resolves in this module without adding a new alias that would change boundary deps (both `Format` and `Plan` are already allowed deps of `Output`).

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/output/clamp_test.exs`
Expected: PASS (both `encoder_limit/1` tests).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/encoder.ex test/image_pipe/output/clamp_test.exs
git commit -m "feat(output): add Encoder.encoder_limit/1 per-format dimension table (#150)"
```

---

## Task 2: `Output.Clamp.clamp/3` — generic uniform downscale

**Files:**
- Create: `lib/image_pipe/output/clamp.ex`
- Test: `test/image_pipe/output/clamp_test.exs` (extend)

- [ ] **Step 1: Write the failing tests**

Append a `describe "clamp/3"` block to `test/image_pipe/output/clamp_test.exs`. These use real `Image` (default `image_module`) and small synthetic images, so every input is a shape a real producer constructs (a realized `Vix.Vips.Image` + an integer/`:infinity` limit):

```elixir
  describe "clamp/3" do
    alias ImagePipe.Output.Clamp

    # A blank image of exact dimensions; cheap and lazy.
    defp image(width, height) do
      {:ok, image} = Image.new(width, height)
      image
    end

    test "returns the image unchanged with nil info when within the limit" do
      img = image(200, 50)
      assert {:ok, ^img, nil} = Clamp.clamp(img, 1000, [])
    end

    test "is a no-op for an :infinity limit" do
      img = image(200, 50)
      assert {:ok, ^img, nil} = Clamp.clamp(img, :infinity, [])
    end

    test "uniformly downscales when the longest axis exceeds the limit" do
      img = image(200, 50)
      assert {:ok, resized, info} = Clamp.clamp(img, 100, [])

      assert Image.width(resized) == 100
      assert Image.height(resized) == 25
      assert info.source_dimensions == {200, 50}
      assert info.dimensions == {100, 25}
      assert info.max_dimension == 100
      assert_in_delta info.scale, 0.5, 1.0e-6
    end

    test "guarantees the realized longest axis is at most the limit (rounding)" do
      # 333 * (100/333) = 100.0 -> round 100; this also exercises the
      # measure-and-verify path that keeps a rounding quirk from exceeding it.
      img = image(333, 10)
      assert {:ok, resized, info} = Clamp.clamp(img, 100, [])

      assert Image.width(resized) <= 100
      assert max(Image.width(resized), Image.height(resized)) <= 100
      assert info.dimensions == {Image.width(resized), Image.height(resized)}
    end
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `mise exec -- mix test test/image_pipe/output/clamp_test.exs`
Expected: FAIL — `ImagePipe.Output.Clamp.clamp/3 is undefined` (the `encoder_limit/1` tests still pass).

- [ ] **Step 3: Implement `ImagePipe.Output.Clamp`**

Create `lib/image_pipe/output/clamp.ex`:

```elixir
defmodule ImagePipe.Output.Clamp do
  @moduledoc false
  # Generic, product-neutral uniform downscale of a realized image so it fits a
  # maximum dimension. Used by the producer with the output encoder's per-format
  # limit (`ImagePipe.Output.Encoder.encoder_limit/1`) so encoding cannot fail.
  # Knows nothing about formats or hosts: it takes a raw `max_dimension`. #165
  # widens this to also accept a `max_pixels` budget.
  #
  # Reads/resizes the image via the `image` library directly (no Transform or
  # Telemetry dependency, per the Output boundary). Resize is lazy; measuring
  # width/height reads libvips header fields (O(1), no pixel realization).

  alias Vix.Vips.Image, as: VixImage

  @type clamp_info :: %{
          scale: float(),
          source_dimensions: {pos_integer(), pos_integer()},
          dimensions: {pos_integer(), pos_integer()},
          max_dimension: pos_integer()
        }

  @spec clamp(VixImage.t(), pos_integer() | :infinity, keyword()) ::
          {:ok, VixImage.t(), clamp_info() | nil}
          | {:error, {:encode, Exception.t(), list()}}
  def clamp(%VixImage{} = image, :infinity, _opts), do: {:ok, image, nil}

  def clamp(%VixImage{} = image, max_dimension, opts)
      when is_integer(max_dimension) and max_dimension > 0 do
    w = Image.width(image)
    h = Image.height(image)
    longest = max(w, h)

    if longest <= max_dimension do
      {:ok, image, nil}
    else
      image_module = Keyword.get(opts, :image_module, Image)
      scale = max_dimension / longest

      with {:ok, resized} <- resize(image_module, image, scale),
           {:ok, resized} <- enforce_limit(image_module, image, resized, max_dimension) do
        {:ok, resized,
         %{
           scale: scale,
           source_dimensions: {w, h},
           dimensions: {Image.width(resized), Image.height(resized)},
           max_dimension: max_dimension
         }}
      end
    end
  end

  # Defensive ≤-limit guarantee: round() at `scale = limit/longest` lands the
  # longest axis exactly on `limit`, but if a libvips rounding quirk overshoots
  # we re-resize the ORIGINAL by a floor-biased factor so the corrected longest
  # axis cannot round back over the limit. In practice this never fires.
  defp enforce_limit(image_module, original, resized, max_dimension) do
    realized = max(Image.width(resized), Image.height(resized))

    if realized <= max_dimension do
      {:ok, resized}
    else
      longest = max(Image.width(original), Image.height(original))
      # floor-bias: subtract a hair so round() cannot bump back to the overshoot
      corrected = (max_dimension - 0.5) / longest
      resize(image_module, original, corrected)
    end
  end

  defp resize(image_module, image, scale) do
    case image_module.resize(image, scale, vertical_scale: scale) do
      {:ok, resized} -> {:ok, resized}
      {:error, reason} -> {:error, encode_error(reason)}
      resized when is_struct(resized, VixImage) -> {:ok, resized}
    end
  end

  defp encode_error(reason) do
    {:encode, RuntimeError.exception("clamp resize failed: #{inspect(reason)}"), []}
  end
end
```

Notes for the implementer:
- `Image.resize/3` returns `{:ok, image} | {:error, reason}` (`deps/image/lib/image.ex:4178`); the `is_struct` clause is a defensive belt-and-suspenders for the alpha path and harmless. It premultiplies alpha internally, so transparent images don't get halos.
- The `{:error, {:encode, exception, stacktrace}}` 3-tuple is **required** — a bare `{:encode, reason}` 2-tuple matches no `handle_processing_error/3` clause in `response/sender.ex` and would crash. This mirrors `runner.ex:205`'s `{:session, reason}` wrapping.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec -- mix test test/image_pipe/output/clamp_test.exs`
Expected: PASS (all `encoder_limit/1` and `clamp/3` cases).

- [ ] **Step 5: Compile cleanly (clamp.ex must satisfy the Output boundary)**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles with no warnings and no `Boundary` violation (clamp.ex references only `Vix`/`Image` external libs).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/output/clamp.ex test/image_pipe/output/clamp_test.exs
git commit -m "feat(output): add Clamp.clamp/3 generic uniform downscale (#150)"
```

---

## Task 3: Export `Clamp` from the Output boundary

**Files:**
- Modify: `lib/image_pipe/output.ex`

- [ ] **Step 1: Add the export**

In `lib/image_pipe/output.ex`, add `Clamp` to the `exports:` list (alphabetical-ish, alongside `Encoder`):

```elixir
  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Format, ImagePipe.Plan],
    exports: [
      Capabilities,
      Clamp,
      Encoder,
      Negotiation,
      Resolved
    ]
```

Do **not** change `deps:` — `Clamp` adds no new boundary dependency.

- [ ] **Step 2: Compile to verify the export resolves**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles cleanly (no `Boundary` "module not exported" error when the producer references `Clamp` in Task 4).

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/output.ex
git commit -m "feat(output): export Output.Clamp from the boundary (#150)"
```

---

## Task 4: Wire the clamp + telemetry into the producer

**Files:**
- Modify: `lib/image_pipe/request/source_session/producer.ex`

- [ ] **Step 1: Add the `Clamp` alias**

In `lib/image_pipe/request/source_session/producer.ex`, add to the `alias` block (after `alias ImagePipe.Output.Encoder`):

```elixir
  alias ImagePipe.Output.Clamp
```

- [ ] **Step 2: Insert the clamp + telemetry into `prepare_first_chunk/1`'s `with`**

Replace the existing `with` chain body (currently `resolve_output` → `Encoder.stream_output` → `first_chunk`) so the clamp runs between negotiation and encode. The full edited `with` head:

```elixir
      with {:ok, decoded} <-
             Processor.fetch_decode_validate_source_with_source_format(
               request.plan,
               request.resolved_source,
               request.opts
             ),
           {:ok, %State{} = final_state} <-
             Processor.process_decoded_source(decoded, request.plan, request.opts),
           {:ok, %Resolved{} = resolved_output} <-
             resolve_output(
               request.output_policy,
               decoded.source_format,
               final_state.image,
               request.opts
             ),
           %{max_dimension: max_dimension} <- Encoder.encoder_limit(resolved_output.format),
           {:ok, image, clamp_info} <-
             Clamp.clamp(final_state.image, max_dimension, request.opts),
           :ok <- emit_clamp_telemetry(clamp_info, resolved_output.format, request.opts),
           {:ok, stream, content_type} <-
             Encoder.stream_output(image, resolved_output, request.opts),
           {:ok, chunk, stream_state} <- first_chunk(stream) do
```

The `else` clause is unchanged (`{:error, reason} -> {:error, reason}` handles the clamp's `{:error, {:encode, ...}}`; `:empty -> :empty`). The `%{max_dimension: ...} <- ...` match always succeeds (map always has the key); it's a binding, not a fallible step.

- [ ] **Step 3: Add the telemetry emitter (private functions)**

Add near `resolve_output/4` (these are private helpers in the same module). `Telemetry` is already aliased and `Telemetry.telemetry_opts/1` / `Telemetry.execute/4` already exist (`telemetry.ex:108,115`):

```elixir
  defp emit_clamp_telemetry(nil, _format, _opts), do: :ok

  defp emit_clamp_telemetry(%{} = info, format, opts) do
    Telemetry.execute(
      Telemetry.telemetry_opts(opts),
      [:output, :clamp],
      %{scale: info.scale},
      %{
        format: format,
        source_dimensions: info.source_dimensions,
        dimensions: info.dimensions,
        max_dimension: info.max_dimension
      }
    )

    :ok
  end
```

- [ ] **Step 4: Compile and run the existing producer/conformance suites (no regression)**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/image_pipe/request/source_session_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS. (No clamp fires yet in existing tests — every result is within 8192 < the encoder limits — so behavior is unchanged. This proves the no-op path is wired without regression.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/request/source_session/producer.ex
git commit -m "feat(request): clamp realized image to encoder limit before encode (#150)"
```

---

## Task 5: Subscribe to + render the `[:output, :clamp]` one-shot in the default Logger

**Files:**
- Modify: `lib/image_pipe/telemetry/logger.ex`

- [ ] **Step 1: Write the failing Logger test**

Add to `test/image_pipe/telemetry/logger_test.exs` (mirrors the existing `[:transform, :detect, :skipped]` warning test at line 100):

```elixir
  test "logs the output clamp one-shot at warning with source -> clamped dims" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :output, :clamp],
          %{scale: 0.91},
          %{
            format: :webp,
            source_dimensions: {18_000, 9_000},
            dimensions: {16_383, 8_191},
            max_dimension: 16_383
          }
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "output clamp: 18000x9000 -> 16383x8191 for webp (max 16383)"
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/telemetry/logger_test.exs`
Expected: FAIL — the event isn't attached, so `capture_log` is empty (no match for `[warning]` / the message).

- [ ] **Step 3: Subscribe the `:output` group + clamp one-shot**

In `lib/image_pipe/telemetry/logger.ex`:

(a) Add `output: []` to `@group_span_events` (makes `:output` a selectable group, included in `:all` via `@all_groups`):

```elixir
  @group_span_events %{
    request: [[:request], [:send]],
    parse: [[:parse]],
    source: [[:source, :resolve], [:source, :fetch], [:source, :fetch_decode]],
    transform: [[:transform, :execute], [:transform, :operation], [:transform, :detect]],
    cache: [[:cache, :lookup], [:cache, :write], [:cache, :admission], [:cache, :warm_start]],
    output: []
  }
```

(b) Add the one-shot list after `@transform_oneshot`:

```elixir
  # output one-shot events (already terminal; not spans)
  @output_oneshot [
    [:output, :clamp]
  ]
```

(c) In `event_names/2`, add the output one-shots alongside cache/transform (after the `transform_oneshots` line):

```elixir
    output_oneshots = if :output in groups, do: @output_oneshot, else: []

    Enum.map(spans ++ cache_oneshots ++ transform_oneshots ++ output_oneshots, fn e ->
      prefix ++ e
    end)
```

- [ ] **Step 4: Render + escalate the clamp event**

(a) Add a `level_for/3` clause **above** the existing `defp level_for(suffix, metadata, base)` (so it wins for clamp events):

```elixir
  defp level_for([:output, :clamp | _], _metadata, _base), do: :warning
```

(b) Add a `message/3` clause **before** the generic fallback (`defp message(suffix, _m, meta)`):

```elixir
  defp message([:output, :clamp | _], _m, meta) do
    {sw, sh} = meta[:source_dimensions]
    {w, h} = meta[:dimensions]

    "image_pipe output clamp: #{sw}x#{sh} -> #{w}x#{h} for #{meta[:format]} (max #{meta[:max_dimension]})"
  end
```

The message *is* the outcome (a downscale occurred) — analogous to the `[:transform, :detect, :blend]` clause, which also omits a separate `outcome/1`. No `:result` key is emitted in clamp metadata, so nothing is swallowed.

- [ ] **Step 5: Run the Logger test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/telemetry/logger_test.exs`
Expected: PASS (the new clamp test plus all existing Logger tests).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/telemetry/logger.ex test/image_pipe/telemetry/logger_test.exs
git commit -m "feat(telemetry): render [:output, :clamp] one-shot at warning in default Logger (#150)"
```

---

## Task 6: Wire-level conformance tests (real encode, decoded dims, telemetry)

**Files:**
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs`

These reuse the file's existing helpers: `call_imgproxy/3`, `dimensions/1` (decodes the body → `{w, h}`), `content_type/1`, the self-send `handle_telemetry_event/4` (line 2379), and the `OriginImage` origin (`beach.jpg`). The default opts use the default telemetry prefix `[:image_pipe]`, so the clamp event is `[:image_pipe, :output, :clamp]`.

**Reachability:** the default `max_result_width/height` is 8192 (< 16383/16384), so each test must raise the host result cap above the encoder limit, and use `el:1` enlargement to push the result just past the limit. A wide-short source keeps the encoded pixel count tiny so AVIF/WebP encode stays fast.

> Determine the `beach.jpg` source dimensions and the exact `w:`/`h:` to land just over 16383/16384 during implementation (decode the fixture or compute from a known size). The assertions below are written to be robust to ±1px rounding: they assert the longest axis is **≤ limit** and **strictly less than the pre-clamp longest axis**, not an exact post-clamp size.

- [ ] **Step 1: Write the failing WebP clamp test**

Add a `describe "output encoder dimension clamp (#150)"` block. Use a helper to attach the clamp telemetry to the test pid (mirrors `attach_source_resolve_telemetry/1`):

```elixir
  describe "output encoder dimension clamp (#150)" do
    defp attach_clamp_telemetry do
      handler_id = {__MODULE__, self(), :output_clamp}

      :telemetry.attach(
        handler_id,
        [:image_pipe, :output, :clamp],
        &__MODULE__.handle_telemetry_event/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    @clamp_opts [
      root_url: "http://origin.test",
      parser: ImagePipe.Parser.Imgproxy,
      req_options: [plug: OriginImage],
      max_result_width: 40_000,
      max_result_height: 40_000,
      max_result_pixels: 2_000_000_000
    ]

    test "downscales a WebP result above the 16383 encoder limit and serves it" do
      attach_clamp_telemetry()

      # el:1 enlarges; w:18000 pushes the WebP result past 16383. f:webp forces
      # the output format so negotiation is deterministic.
      conn = call_imgproxy("/_/el:1/w:18000/f:webp/plain/images/beach.jpg", @clamp_opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/webp"]

      {w, h} = dimensions(conn)
      assert max(w, h) <= 16_383
      assert max(w, h) > 8_192

      assert_received {:telemetry_event, [:image_pipe, :output, :clamp], %{scale: scale},
                       meta}

      assert scale < 1.0
      assert meta.format == :webp
      assert meta.max_dimension == 16_383
      assert meta.dimensions == {w, h}
      {sw, sh} = meta.source_dimensions
      assert max(sw, sh) > 16_383
    end
```

- [ ] **Step 2: Run it to verify it fails (before implementation) — or passes (after Tasks 1-5)**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs -k "downscales a WebP result"`
Expected after Tasks 1–5: PASS. (If executed before the production code lands, it would fail because no clamp event fires and the encode would error at > 16383.) This task is the integration proof of Tasks 1–5; keep it green.

If it fails on the chosen `w:` not exceeding 16383 (source aspect ratio), adjust `w:`/`h:`/`el` so the pre-clamp longest axis is clearly > 16383, then re-run.

- [ ] **Step 3: Add the AVIF clamp test**

```elixir
    test "downscales an AVIF result above the 16384 encoder limit and serves it" do
      attach_clamp_telemetry()

      conn = call_imgproxy("/_/el:1/w:18000/f:avif/plain/images/beach.jpg", @clamp_opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/avif"]

      {w, h} = dimensions(conn)
      assert max(w, h) <= 16_384
      assert max(w, h) > 8_192

      assert_received {:telemetry_event, [:image_pipe, :output, :clamp], %{scale: scale},
                       meta}

      assert scale < 1.0
      assert meta.format == :avif
      assert meta.max_dimension == 16_384
      assert meta.dimensions == {w, h}
    end
```

- [ ] **Step 4: Add the no-clamp control**

```elixir
    test "does not clamp or emit when a WebP result is within the encoder limit" do
      attach_clamp_telemetry()

      conn = call_imgproxy("/_/w:120/f:webp/plain/images/beach.jpg", @clamp_opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/webp"]
      {w, _h} = dimensions(conn)
      assert w == 120

      refute_received {:telemetry_event, [:image_pipe, :output, :clamp], _measurements, _meta}
    end
  end
```

- [ ] **Step 5: Run the whole clamp describe block**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs -k "output encoder dimension clamp"`
Expected: PASS (all three tests).

- [ ] **Step 6: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(output): wire-level WebP/AVIF dimension-clamp conformance tests (#150)"
```

---

## Task 7: Document the telemetry event

**Files:**
- Modify: `docs/telemetry.md`

- [ ] **Step 1: Add the `[:output, :clamp]` entry**

In `docs/telemetry.md`, add an entry where one-shot events are documented (the file documents `[:http_cache, …]` one-shots as precedent; place `[:output, :clamp]` consistently with how other one-shots and the default-Logger rendering are listed):

```markdown
### `[:image_pipe, :output, :clamp]` (one-shot)

Emitted when the realized final image exceeded the negotiated output encoder's
hard dimension limit and was uniformly downscaled to fit before encoding
(format-aware; WebP 16383, AVIF 16384). Lets a host observe that a served image
was downscaled rather than delivered at the requested size.

- **Measurements:** `%{scale: float()}` — the uniform downscale factor (`< 1.0`).
- **Metadata:** `%{format: atom(), source_dimensions: {w, h}, dimensions: {w, h}, max_dimension: pos_integer()}` — pre- and post-clamp dimensions and the limit that bound them. All non-sensitive (no URLs/secrets/PII).
- **Default Logger:** rendered at `:warning` (e.g. `output clamp: 18000x9000 -> 16383x8191 for webp (max 16383)`), matching imgproxy's `slog.Warn`.
```

Match the surrounding heading style/level of the existing event docs in the file.

- [ ] **Step 2: Verify docs reference the event the Logger actually attaches to**

Confirm the documented event name `[:image_pipe, :output, :clamp]` and the `:warning` rendering match Task 5's Logger wiring. (No command — a read-through against `logger.ex`.)

- [ ] **Step 3: Commit**

```bash
git add docs/telemetry.md
git commit -m "docs(telemetry): document [:output, :clamp] dimension-clamp event (#150)"
```

---

## Task 8: Full precommit gate

**Files:** none (verification only).

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
(This runs `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`.)
Expected: all green. If `mix format` reports changes, run `mise exec -- mix format`, review, and amend the relevant commit.

- [ ] **Step 2: Confirm no demo change is needed**

This is an internal output safety clamp with no user-facing URL knob, so the `demo/` app needs no update (the demo-sync guideline applies only to transform/parser-option changes). No action — recorded here so the omission is deliberate.

- [ ] **Step 3: Final review against the spec**

Re-read `docs/superpowers/specs/2026-06-08-output-encoder-dimension-clamp-design.md` and confirm: dimension-only `clamp/3` (no `max_pixels`), 3-tuple encode-error contract, clamp before `finalize`, no cache-key change, telemetry one-shot + Logger sync + docs, wire tests in the conformance file. (No command.)

---

## Self-Review Notes (author)

- **Spec coverage:** encoder_limit table (T1), generic clamp + ≤-limit guarantee + error contract + no-op laziness + alpha (T2), boundary export (T3), producer seam before stream_output (T4), telemetry one-shot + Logger subscription/level/message (T5), wire WebP/AVIF + no-clamp control with decoded dims (T6), docs (T7), no-cache-change + no-demo-change confirmed (T4/T8). #165 deferral honored — no `max_pixels` anywhere.
- **No placeholders:** every code step has full code. The one runtime unknown (exact `beach.jpg`-derived `w:` to exceed the limit) is explicitly flagged in T6 with robust ≤-limit/strictly-reduced assertions instead of brittle exact dims.
- **Type/name consistency:** `clamp/3`, `encoder_limit/1`, `clamp_info` keys (`scale`, `source_dimensions`, `dimensions`, `max_dimension`), event `[:output, :clamp]`, measurements `%{scale: ...}` are identical across Clamp, producer, Logger, tests, and docs.
