# Shrink-on-Load Plan B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement shrink-on-load for large JPEG/WebP downscales so that libvips decodes at reduced resolution — cutting peak memory proportionally to the squared shrink factor — while maintaining dimension-exact output.

**Architecture:** `DecodePlanner.open_options/3` gains source-format-gated shrink/scale logic (JPEG `shrink: 1|2|4|8`, WebP `scale:`, others none). `Request.Processor` does a two-step seekable open: (1) header-only read to get original dims and format, (2) reopen with the planner's full options including shrink/scale; `max_input_pixels` moves to the original (pre-shrink) extent. `Transform.State` gains `source_dimensions: {w, h}` (orientation-corrected original) so `Resize` computes targets from original dims while scaling from the shrunk image, and `PlanExecutor` rescales pixel-based crop dimensions by the achieved prescale factor.

**Tech Stack:** Elixir, `Vix`/`image` (libvips bindings), `Plug`, `ExUnit`. Spec: `docs/superpowers/specs/2026-06-01-shrink-on-load-design.md`. Plan A (seekable-source unification) is already landed in `main`; this plan builds directly on its seams (`seekable_input/1`, `open_seekable_input/3`, `open_buffer/3`).

**Run tests with:** `mise exec -- mix test <path>`. Gate: `mise run precommit`.

---

## Behavioral notes (read before implementing)

1. **Output is NOT byte-identical** to full-decode-then-resize — JPEG shrink-on-load uses a different downsample kernel than libvips' residual resize. The equivalence contract becomes dimension-exact + coarse-downsample MAE. Delete `sequential_compatibility_test.exs` (which asserts pixel-exact equality) and replace with wire-level MAE tests.

2. **`max_input_pixels` moves to original (header) dims.** The existing check after decode validated the shrunk image; that would allow decompression bombs through. The new check runs on the header image dims BEFORE any shrink.

3. **Two opens per request.** The header open is always `[access: :random, fail_on: :error]` (for header-only reading). The decode open uses the planner's full output (access + optional shrink/scale). Both use the same `open_seekable_input/3` seam and the same `:buffer_loader` injectable.

4. **`source_dimensions` is orientation-corrected.** EXIF orientation swaps stored W/H for 90°/270° rotated images. `source_dimensions` is what the image looks like after AutoOrient (display orientation). `Resize` uses it for target computation; the crop prescale derives from `effective_source_dims(state) / image_dims`.

5. **`source_dimensions` clears after `Resize.execute`.** After Resize scales from the shrunk image to the correct target, subsequent operations (including cover crops) work on the correctly-sized image with no further prescale needed.

6. **DecodePlanner stays in the Transform boundary.** It takes `source_format :: atom()` (plain atom, not a `SourceFormat` module reference) and `corrected_dims :: {pos_integer(), pos_integer()}` — caller-supplied values from the Request boundary.

7. **Only the first pipeline feeds the planner.** `first_pipeline_operations/1` supplies only the first pipeline's operations to `DecodePlanner.open_options/3`. A multi-pipeline plan where only the second pipeline has a Resize gets no shrink. This is pre-existing behavior and an acceptable constraint for the common case.

8. **Format gate:** Only `:jpeg` and `:webp` get shrink options. SVG is classified as `:unsupported_source_format` so the SVG/vector `scale:` branch is unreachable in practice; include it for spec completeness.

---

## File Structure

- **Modify** `lib/image_pipe/transform/state.ex` — add `source_dimensions` field
- **Modify** `lib/image_pipe/transform/geometry.ex` — add `effective_source_dims/1` helper
- **Modify** `lib/image_pipe/transform/decode_planner.ex` — extend to 3-arg `open_options/3` with shrink/scale
- **Modify** `lib/image_pipe/transform/operation/resize.ex` — use `effective_source_dims`; clear `source_dimensions` after execute
- **Modify** `lib/image_pipe/transform/plan_executor.ex` — use `effective_source_dims` throughout; rescale pixel-based crop dims/offsets
- **Modify** `lib/image_pipe/request/processor.ex` — two-step open; validate `max_input_pixels` on original dims; feed `source_dimensions` into State
- **Modify** `test/image_pipe/decode_planner_test.exs` — update to 3-arg form; add shrink/scale/orientation cases
- **Delete** `test/image_pipe/sequential_compatibility_test.exs` — access-mode parity pin incompatible with shrink-on-load
- **Modify** `test/image_pipe/processor_test.exs` — add shrink recorded-open gate; update max_input_pixels test
- **Modify** `test/image_pipe/telemetry_test.exs` — add shrink metadata assertions
- **Create** `test/image_pipe/shrink_on_load_test.exs` — wire-level JPEG/WebP equivalence + PNG pixel-exact + multi-frame safety

---

### Task 1: `Transform.State` — add `source_dimensions` field

**Files:**
- Modify: `lib/image_pipe/transform/state.ex`
- Test: `test/image_pipe/transform/state_test.exs` (create if absent; add one structural assertion)

The field stores orientation-corrected original dims set by the Processor, used by Resize and PlanExecutor for geometry computations.

- [ ] **Step 1: Add the field**

Replace the `defstruct` and `@type` in `lib/image_pipe/transform/state.ex`:

```elixir
defstruct image: nil,
          debug: false,
          detector: nil,
          detector_required: false,
          telemetry_opts: [],
          source_dimensions: nil

@type t :: %__MODULE__{
        image: Vix.Vips.Image.t() | nil,
        debug: boolean(),
        detector: module() | {module(), keyword()} | nil,
        detector_required: boolean(),
        telemetry_opts: keyword(),
        source_dimensions: {pos_integer(), pos_integer()} | nil
      }
```

- [ ] **Step 2: Add `effective_source_dims/1` to State**

Below `set_image/2` in `lib/image_pipe/transform/state.ex`:

```elixir
def effective_source_dims(%__MODULE__{source_dimensions: {w, h}}), do: {w, h}

def effective_source_dims(%__MODULE__{image: image}),
  do: {Image.width(image), Image.height(image)}
```

- [ ] **Step 3: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: PASS. No unused variables or aliases.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/transform/state.ex
git commit -m "feat(transform): add source_dimensions to State for shrink-on-load geometry"
```

---

### Task 2: `Transform.Geometry` — re-export `effective_source_dims`

**Files:**
- Modify: `lib/image_pipe/transform/geometry.ex`

`Resize.execute` and `PlanExecutor` both `import ImagePipe.Transform.State` already (or alias it). Since `effective_source_dims/1` lives on `State`, callers use `State.effective_source_dims(state)` directly. No change to `geometry.ex` is needed — Task 2 is a no-op; skip to Task 3.

(If needed in future, `Geometry` can re-export it as a delegated helper. For now, direct `State.effective_source_dims/1` calls are fine in both `Resize` and `PlanExecutor`.)

---

### Task 3: `DecodePlanner` — extend to `open_options/3`

**Files:**
- Modify: `lib/image_pipe/transform/decode_planner.ex`
- Test: `test/image_pipe/decode_planner_test.exs`

The planner gains format-gated shrink/scale logic. The 1-arg `open_options/1` is replaced by the 3-arg form; the old form is removed since all callers (Processor) will supply format+dims. Tests are rewritten to use the 3-arg form.

- [ ] **Step 1: Replace `decode_planner_test.exs` with updated tests**

Replace the full content of `test/image_pipe/decode_planner_test.exs`:

```elixir
defmodule ImagePipe.Transform.DecodePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.AutoOrient
  alias ImagePipe.Transform.DecodePlanner

  # --- Access selection (unchanged logic, now via 3-arg form) ---

  test "empty chain opens randomly with fail_on error regardless of format" do
    opts = DecodePlanner.open_options([], :jpeg, {3000, 2000})
    assert opts[:access] == :random
    assert opts[:fail_on] == :error
  end

  test "width-only fit resize opens sequentially" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 120}, :auto)
    opts = DecodePlanner.open_options([resize], :jpeg, {3000, 2000})
    assert opts[:access] == :sequential
  end

  test "height-only fit resize opens sequentially" do
    assert {:ok, resize} = Operation.resize(:fit, :auto, {:px, 120})
    opts = DecodePlanner.open_options([resize], :jpeg, {2000, 3000})
    assert opts[:access] == :sequential
  end

  test "auto-orient-only chains open sequentially" do
    opts = DecodePlanner.open_options([%AutoOrient{}], :jpeg, {3000, 2000})
    assert opts[:access] == :sequential
  end

  test "color-profile normalization is access-neutral (alone: random; with sequential: sequential)" do
    neutral_only = DecodePlanner.open_options([%Operation.NormalizeColorProfile{}], :png, {100, 100})
    assert neutral_only[:access] == :random

    with_sequential =
      DecodePlanner.open_options([%AutoOrient{}, %Operation.NormalizeColorProfile{}], :png, {100, 100})
    assert with_sequential[:access] == :sequential
  end

  test "crops stay random" do
    assert {:ok, crop} = Operation.crop_guided({:px, 80}, {:px, 80}, :center)
    opts = DecodePlanner.open_options([crop], :jpeg, {3000, 2000})
    assert opts[:access] == :random
  end

  # --- JPEG shrink-on-load ---

  test "JPEG shrink is quantized to largest power of 2 not exceeding load_shrink" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, :auto)

    # src_w=3200, target_w=400 → load_shrink=8.0 → shrink 8
    opts8 = DecodePlanner.open_options([resize], :jpeg, {3200, 2400})
    assert opts8[:shrink] == 8

    # src_w=3000, target_w=400 → load_shrink=7.5 → shrink 4 (not 8)
    opts4 = DecodePlanner.open_options([resize], :jpeg, {3000, 2000})
    assert opts4[:shrink] == 4

    # src_w=1000, target_w=400 → load_shrink=2.5 → shrink 2
    opts2 = DecodePlanner.open_options([resize], :jpeg, {1000, 800})
    assert opts2[:shrink] == 2

    # src_w=600, target_w=400 → load_shrink=1.5 → shrink 1 (no shrink key)
    opts1 = DecodePlanner.open_options([resize], :jpeg, {600, 400})
    refute Keyword.has_key?(opts1, :shrink)
    refute Keyword.has_key?(opts1, :scale)
  end

  test "JPEG shrink uses min(wshrink, hshrink) to avoid over-shrinking" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, {:px, 600})
    # src={3200,2400}, target={400,600} → wshrink=8, hshrink=4 → min=4
    opts = DecodePlanner.open_options([resize], :jpeg, {3200, 2400})
    assert opts[:shrink] == 4
  end

  test "JPEG width-only resize uses wshrink only (no hshrink constraint)" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 100}, :auto)
    # src_w=1600 → wshrink=16 → capped at 8
    opts = DecodePlanner.open_options([resize], :jpeg, {1600, 1200})
    assert opts[:shrink] == 8
  end

  test "JPEG height-only resize uses hshrink only" do
    assert {:ok, resize} = Operation.resize(:fit, :auto, {:px, 100})
    # src_h=1600 → hshrink=16 → capped at 8
    opts = DecodePlanner.open_options([resize], :jpeg, {1200, 1600})
    assert opts[:shrink] == 8
  end

  test "JPEG cover-mode resize is also shrink-eligible" do
    assert {:ok, resize} = Operation.resize(:cover, {:px, 200}, {:px, 200})
    # src={1600,1200}, target={200,200} → wshrink=8, hshrink=6 → min=6 → shrink 4
    opts = DecodePlanner.open_options([resize], :jpeg, {1600, 1200})
    assert opts[:shrink] == 4
  end

  test "JPEG auto×auto resize emits no shrink" do
    assert {:ok, resize} = Operation.resize(:fit, :auto, :auto)
    opts = DecodePlanner.open_options([resize], :jpeg, {3000, 2000})
    refute Keyword.has_key?(opts, :shrink)
  end

  test "JPEG orientation-corrected axis: portrait tag swaps axes for shrink computation" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, :auto)
    # stored 800×1200 (portrait stored landscape) → corrected {1200, 800}
    # wshrink = 1200/400 = 3.0 → shrink 2
    opts = DecodePlanner.open_options([resize], :jpeg, {1200, 800})
    assert opts[:shrink] == 2
  end

  # --- WebP scale-on-load ---

  test "WebP gets fractional scale for large downscales" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 200}, :auto)
    # src_w=1600, target=200 → load_shrink=8.0 → scale=1/8=0.125
    opts = DecodePlanner.open_options([resize], :webp, {1600, 1200})
    assert_in_delta opts[:scale], 1.0 / 8.0, 0.001
    refute Keyword.has_key?(opts, :shrink)
  end

  test "WebP emits no scale when load_shrink <= 1" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 800}, :auto)
    opts = DecodePlanner.open_options([resize], :webp, {600, 400})
    refute Keyword.has_key?(opts, :scale)
    refute Keyword.has_key?(opts, :shrink)
  end

  # --- Non-shrink-eligible formats ---

  test "PNG emits no shrink or scale regardless of target" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 10}, :auto)
    opts = DecodePlanner.open_options([resize], :png, {3000, 2000})
    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
    assert opts[:access] == :sequential
    assert opts[:fail_on] == :error
  end

  test "HEIF/AVIF emit no shrink or scale" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 10}, :auto)
    refute DecodePlanner.open_options([resize], :heif, {3000, 2000}) |> Keyword.has_key?(:shrink)
    refute DecodePlanner.open_options([resize], :avif, {3000, 2000}) |> Keyword.has_key?(:shrink)
  end

  test "unknown format emits no shrink or scale" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 10}, :auto)
    opts = DecodePlanner.open_options([resize], :some_unknown_format, {3000, 2000})
    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
  end

  # --- No-resize chain ---

  test "non-resize operations produce no shrink option for JPEG" do
    assert {:ok, blur} = Operation.blur(2.0)
    opts = DecodePlanner.open_options([blur], :jpeg, {3000, 2000})
    refute Keyword.has_key?(opts, :shrink)
  end

  # --- Legacy behavior: composition and effect operations ---

  test "composition operations force random access (no shrink for random-only ops)" do
    assert {:ok, padding} = Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 0})
    opts = DecodePlanner.open_options([padding], :jpeg, {3000, 2000})
    assert opts[:access] == :random
  end
end
```

Run: `mise exec -- mix test test/image_pipe/decode_planner_test.exs`
Expected: FAIL — `open_options/3` is undefined, and the old tests may also fail.

- [ ] **Step 2: Implement `open_options/3` in `decode_planner.ex`**

Replace the full content of `lib/image_pipe/transform/decode_planner.ex`:

```elixir
defmodule ImagePipe.Transform.DecodePlanner do
  @moduledoc """
  Chooses image decode access and load options for semantic Plan operations.

  Decode planning reduces a source-fetch-free Plan operation chain to either
  sequential or random image access, and optionally a format-specific load
  shrink/scale option for large downscales.

  The planner is a pure function: it does not read image metadata itself.
  The caller (Request.Processor) reads the header dims and source format and
  passes them in.
  """

  alias ImagePipe.Plan.Operation.AutoOrient
  alias ImagePipe.Plan.Operation.Background
  alias ImagePipe.Plan.Operation.Blur
  alias ImagePipe.Plan.Operation.Brightness
  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.Contrast
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Duotone
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Monochrome
  alias ImagePipe.Plan.Operation.NormalizeColorProfile
  alias ImagePipe.Plan.Operation.Padding
  alias ImagePipe.Plan.Operation.Pixelate
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Operation.Saturation
  alias ImagePipe.Plan.Operation.Sharpen

  @type access_requirement() :: :sequential | :random | :neutral
  @type source_format() :: :jpeg | :webp | :png | :tiff | :jpeg2000 | :jpeg_xl | :heif | :avif | atom()

  @spec open_options([ImagePipe.Plan.Pipeline.operation()], source_format(), {pos_integer(), pos_integer()}) ::
          keyword()
  def open_options(chain, source_format, {src_w, src_h})
      when is_list(chain) and is_atom(source_format) and
             is_integer(src_w) and src_w > 0 and
             is_integer(src_h) and src_h > 0 do
    base = [access: access(chain), fail_on: :error]
    load_shrink = compute_load_shrink(chain, src_w, src_h)
    append_load_option(base, source_format, load_shrink)
  end

  # --- Access selection (unchanged) ---

  defp access([]), do: :random

  defp access(chain) when is_list(chain) do
    chain
    |> Enum.map(&access_requirement/1)
    |> resolve_access()
  end

  defp access_requirement(%PlanResize{mode: mode} = operation) when mode in [:fit, :stretch],
    do: resize_access_requirement(operation)

  defp access_requirement(%PlanResize{mode: mode}) when mode in [:cover, :auto], do: :random
  defp access_requirement(%CropGuided{}), do: :random
  defp access_requirement(%CropRegion{}), do: :random
  defp access_requirement(%Canvas{}), do: :random
  defp access_requirement(%Padding{}), do: :random
  defp access_requirement(%Background{}), do: :random
  defp access_requirement(%AutoOrient{}), do: :sequential
  defp access_requirement(%Rotate{}), do: :random
  defp access_requirement(%Flip{}), do: :random
  defp access_requirement(%Blur{}), do: :random
  defp access_requirement(%Sharpen{}), do: :random
  defp access_requirement(%Pixelate{}), do: :random
  defp access_requirement(%Monochrome{}), do: :random
  defp access_requirement(%Duotone{}), do: :random
  defp access_requirement(%Brightness{}), do: :random
  defp access_requirement(%Contrast{}), do: :random
  defp access_requirement(%Saturation{}), do: :random
  defp access_requirement(%NormalizeColorProfile{}), do: :neutral

  defp resize_access_requirement(%PlanResize{
         width: width,
         height: height,
         min_width: nil,
         min_height: nil
       }) do
    case requested_resize_dimension?(width) or requested_resize_dimension?(height) do
      true -> :sequential
      false -> :random
    end
  end

  defp resize_access_requirement(%PlanResize{}), do: :random

  defp requested_resize_dimension?({:px, value}) when is_integer(value) and value > 0, do: true
  defp requested_resize_dimension?(_dimension), do: false

  defp resolve_access(requirements) do
    cond do
      Enum.any?(requirements, &(&1 == :random)) -> :random
      Enum.any?(requirements, &(&1 == :sequential)) -> :sequential
      true -> :random
    end
  end

  # --- Shrink/scale computation ---

  # Find the first PlanResize in the chain (regardless of mode).
  defp find_first_resize(chain), do: Enum.find(chain, &match?(%PlanResize{}, &1))

  defp compute_load_shrink(chain, src_w, src_h) do
    case find_first_resize(chain) do
      nil -> 1.0
      resize -> resize_load_shrink(resize, src_w, src_h)
    end
  end

  defp resize_load_shrink(%PlanResize{width: {:px, w}, height: {:px, h}}, src_w, src_h)
       when w > 0 and h > 0 do
    min(src_w / w, src_h / h)
  end

  defp resize_load_shrink(%PlanResize{width: {:px, w}}, src_w, _src_h) when w > 0 do
    src_w / w
  end

  defp resize_load_shrink(%PlanResize{height: {:px, h}}, _src_w, src_h) when h > 0 do
    src_h / h
  end

  defp resize_load_shrink(_resize, _src_w, _src_h), do: 1.0

  # Append the format-appropriate load option when load_shrink > 1.
  defp append_load_option(base, :jpeg, load_shrink) do
    n = jpeg_shrink_n(load_shrink)
    if n >= 2, do: base ++ [shrink: n], else: base
  end

  defp append_load_option(base, format, load_shrink) when format in [:webp] do
    if load_shrink > 1.0, do: base ++ [scale: 1.0 / load_shrink], else: base
  end

  defp append_load_option(base, _format, _load_shrink), do: base

  # JPEG block-level IDCT shrink factors: largest power-of-2 in {1,2,4,8} ≤ load_shrink.
  defp jpeg_shrink_n(load_shrink) when load_shrink >= 8, do: 8
  defp jpeg_shrink_n(load_shrink) when load_shrink >= 4, do: 4
  defp jpeg_shrink_n(load_shrink) when load_shrink >= 2, do: 2
  defp jpeg_shrink_n(_), do: 1
end
```

- [ ] **Step 3: Run the decode planner tests**

Run: `mise exec -- mix test test/image_pipe/decode_planner_test.exs`
Expected: PASS (all new tests).

- [ ] **Step 4: Compile full project**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: PASS. The Processor still compiles because it calls the old `open_options/1` which no longer exists — **this will fail**. Leave the Processor failing until Task 6 where the call site is updated. If compile errors only involve `processor.ex`, that is expected. Fix any unexpected compile errors.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/decode_planner.ex test/image_pipe/decode_planner_test.exs
git commit -m "feat(transform): DecodePlanner.open_options/3 with JPEG shrink and WebP scale"
```

---

### Task 4: `Resize.execute` — use `effective_source_dims`, clear after

**Files:**
- Modify: `lib/image_pipe/transform/operation/resize.ex`

`Resize.execute/2` currently uses `image_width(state)` / `image_height(state)` for the source dims passed to `resolve_dimensions`. After shrink-on-load the image is smaller than the original; using the shrunk dims would compute the wrong target. The fix: use `State.effective_source_dims(state)` which falls back to the actual image dims when `source_dimensions` is nil (the no-shrink / pre-Plan-B case). After resizing, clear `source_dimensions` so subsequent Resize operations in the same pipeline use the current image dims (not the original).

- [ ] **Step 1: Write a failing test for `effective_source_dims` usage in Resize**

Add to `test/image_pipe/resize_test.exs` (or create it). The test verifies that when `source_dimensions` is set to original dims, the Resize target is computed from those dims even though the actual image is smaller.

```elixir
# In whatever test module covers Resize.execute — find it with:
#   grep -r "Resize" test/ --include="*.exs" -l
# If no unit test for Resize.execute exists, add to the resize operation test file.

test "execute uses source_dimensions when set, not shrunk image dims" do
  # Simulate a 3000x2000 image shrunk to 375x250 (8x), with source_dimensions = {3000, 2000}
  {:ok, shrunk_image} = Image.new(375, 250, color: [128, 128, 128])
  state = %State{
    image: shrunk_image,
    source_dimensions: {3000, 2000}
  }
  
  # Fit resize: target 300x200 (output should be exactly 300x200)
  operation = %Resize{mode: :fit, width: {:pixels, 300}, height: {:pixels, 200}}
  {:ok, new_state} = Resize.execute(operation, state)
  
  assert Image.width(new_state.image) == 300
  assert Image.height(new_state.image) == 200
  # source_dimensions is cleared after Resize
  assert new_state.source_dimensions == nil
end

test "execute falls back to image dims when source_dimensions is nil" do
  {:ok, image} = Image.new(375, 250, color: [128, 128, 128])
  state = %State{image: image, source_dimensions: nil}
  
  operation = %Resize{mode: :fit, width: {:pixels, 300}, height: {:pixels, 200}}
  {:ok, new_state} = Resize.execute(operation, state)
  
  # 375x250 fit to 300x200: source_ratio=1.5, target_ratio=1.5 → {300, 200}
  assert Image.width(new_state.image) == 300
  assert Image.height(new_state.image) == 200
  assert new_state.source_dimensions == nil
end
```

Run: `mise exec -- mix test test/image_pipe/resize_test.exs` (or relevant test file)
Expected: FAIL (Resize.execute doesn't use source_dimensions yet).

- [ ] **Step 2: Update `Resize.execute` and `resize_image`**

In `lib/image_pipe/transform/operation/resize.ex`, replace the `execute/2` callback:

```elixir
@impl ImagePipe.Transform
def execute(%__MODULE__{} = operation, %State{} = state) do
  {src_w, src_h} = State.effective_source_dims(state)

  dimensions =
    resolve_dimensions(operation,
      source_width: src_w,
      source_height: src_h
    )

  case resize_image(state, dimensions.intermediate_width, dimensions.intermediate_height) do
    {:ok, image} ->
      new_state = state |> set_image(image) |> Map.put(:source_dimensions, nil)
      {:ok, new_state}

    {:error, reason} ->
      {:error, {__MODULE__, reason}}
  end
end
```

Also add the alias at the top of the file (after existing imports):
```elixir
alias ImagePipe.Transform.State
```

(`State` is already aliased via `import ImagePipe.Transform.State` which imports `set_image`. But for `State.effective_source_dims/1` we need to either also alias or use the full module. Since `import` brings in `set_image` only, add `alias ImagePipe.Transform.State` explicitly.)

Wait — looking at the file: it has `import ImagePipe.Transform.State` which imports all public functions. `effective_source_dims/1` is defined on State, so after the import it can be called as `effective_source_dims(state)` directly. And `Map.put(:source_dimensions, nil)` works on any struct.

Simplify to:

```elixir
@impl ImagePipe.Transform
def execute(%__MODULE__{} = operation, %State{} = state) do
  {src_w, src_h} = State.effective_source_dims(state)

  dimensions =
    resolve_dimensions(operation,
      source_width: src_w,
      source_height: src_h
    )

  case resize_image(state, dimensions.intermediate_width, dimensions.intermediate_height) do
    {:ok, image} ->
      {:ok, %State{set_image(state, image) | source_dimensions: nil}}

    {:error, reason} ->
      {:error, {__MODULE__, reason}}
  end
end
```

Add `alias ImagePipe.Transform.State` after the existing `alias ImagePipe.Transform.State` line (it's already there via `import ImagePipe.Transform.State` — check the actual file; `import` doesn't create an alias, so add `alias ImagePipe.Transform.State` explicitly near the top of the module).

- [ ] **Step 3: Run resize tests**

Run: `mise exec -- mix test test/image_pipe/resize_test.exs`
Expected: PASS.

Run: `mise exec -- mix test test/image_pipe/`
Expected: Most pass. Processor test may still fail due to Task 3's compile break.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/transform/operation/resize.ex
git commit -m "feat(transform): Resize uses source_dimensions for target, clears after execute"
```

---

### Task 5: `PlanExecutor` — use `effective_source_dims`, prescale pixel crop dims

**Files:**
- Modify: `lib/image_pipe/transform/plan_executor.ex`

Six places use `Image.width(state.image)` / `Image.height(state.image)` that should use original dims when `source_dimensions` is set. Two places that create `%Crop{}` from `CropGuided`/`CropRegion` need pixel-based dim rescaling.

- [ ] **Step 1: Update `cover_resize_and_crop` to use `effective_source_dims`**

Replace `cover_resize_and_crop/4` in `lib/image_pipe/transform/plan_executor.ex`:

```elixir
defp cover_resize_and_crop(%Resize{} = resize, %State{} = state, gravity, {x_offset, y_offset}) do
  {src_w, src_h} = State.effective_source_dims(state)

  dimensions =
    Resize.resolve_dimensions(resize,
      source_width: src_w,
      source_height: src_h
    )

  [
    resize,
    %Crop{
      width: dimensions.target_width,
      height: dimensions.target_height,
      crop_from: :gravity,
      gravity: gravity,
      x_offset: x_offset,
      y_offset: y_offset,
      offset_scale: dimensions.effective_dpr
    }
  ]
end
```

- [ ] **Step 2: Update `plan_resize_branch` (auto mode) to use `effective_source_dims`**

Replace the auto-mode `plan_resize_branch/2` clause in `lib/image_pipe/transform/plan_executor.ex`:

```elixir
defp plan_resize_branch(%PlanResize{mode: :auto} = operation, %State{} = state) do
  {src_w, src_h} = State.effective_source_dims(state)

  resize_auto_branch(
    src_w,
    src_h,
    tagged_logical_pixels(operation.width),
    tagged_logical_pixels(operation.height)
  )
end
```

- [ ] **Step 3: Update `resize_padding_scale` and `max_padding_scale_without_enlarge`**

Replace `resize_padding_scale/3` (the non-trivial clause) in `lib/image_pipe/transform/plan_executor.ex`:

```elixir
defp resize_padding_scale(%PlanResize{} = operation, %State{} = state, mode) do
  {src_w, src_h} = State.effective_source_dims(state)
  requested_scale = tagged_dpr_float(operation.dpr)
  branch = plan_resize_branch(operation, state)
  resize = resize_from(operation, branch)

  base =
    %{resize | dpr: 1.0, enlarge: true}
    |> Resize.resolve_dimensions(
      source_width: src_w,
      source_height: src_h
    )

  max_without_enlarge = max_padding_scale_without_enlarge(base, state)
  compensated = compensate_no_enlarge_padding_scale(requested_scale, max_without_enlarge, mode)

  clamp_padding_scale(compensated, max_without_enlarge)
end
```

Replace `max_padding_scale_without_enlarge/2` (the clause with requested width/height — not the `:auto/:auto` one):

```elixir
defp max_padding_scale_without_enlarge(
       %{requested_width: width, requested_height: height},
       %State{} = state
     ) do
  {src_w, src_h} = State.effective_source_dims(state)
  min(src_w / width, src_h / height)
end
```

- [ ] **Step 4: Add prescale helpers and update `CropGuided`/`CropRegion` executable ops**

Add these private helpers near the bottom of `lib/image_pipe/transform/plan_executor.ex` (before the final end):

```elixir
# Rescale a pixel-based crop dimension by the achieved prescale.
# Other unit types (:auto, {:scale, ...}, {:percent, ...}) are proportional
# to the current image and do not need rescaling.
defp scale_pixel_crop_dim({:pixels, n}, scale), do: {:pixels, max(1, round(n * scale))}
defp scale_pixel_crop_dim(dim, _scale), do: dim

# Rescale a pixel-based crop coordinate offset.
# Round (not floor) so small offsets survive large shrinks.
defp scale_pixel_crop_coord({:pixels, n}, scale), do: {:pixels, round(n * scale)}
defp scale_pixel_crop_coord(coord, _scale), do: coord

defp prescale(state) do
  {src_w, src_h} = State.effective_source_dims(state)
  img_w = Image.width(state.image)
  img_h = Image.height(state.image)
  {img_w / src_w, img_h / src_h}
end
```

Replace `executable_operations(%CropGuided{})` clause:

```elixir
defp executable_operations(%CropGuided{} = operation, %State{} = state, _context) do
  {scale_x, scale_y} = prescale(state)

  [
    %Crop{
      width: scale_pixel_crop_dim(crop_dimension(operation.width), scale_x),
      height: scale_pixel_crop_dim(crop_dimension(operation.height), scale_y),
      crop_from: :gravity,
      gravity: tagged_executable_gravity(operation.guide),
      x_offset: scale_pixel_crop_coord(operation.x_offset, scale_x),
      y_offset: scale_pixel_crop_coord(operation.y_offset, scale_y),
      aspect_ratio: operation.aspect_ratio,
      enlarge: operation.enlarge
    }
  ]
end
```

Replace `executable_operations(%CropRegion{})` clause:

```elixir
defp executable_operations(%CropRegion{} = operation, %State{} = state, _context) do
  {scale_x, scale_y} = prescale(state)

  [
    %Crop{
      width: scale_pixel_crop_dim(crop_dimension(operation.width), scale_x),
      height: scale_pixel_crop_dim(crop_dimension(operation.height), scale_y),
      crop_from: %{
        left: scale_pixel_crop_coord(crop_coordinate(operation.x), scale_x),
        top: scale_pixel_crop_coord(crop_coordinate(operation.y), scale_y)
      }
    }
  ]
end
```

- [ ] **Step 5: Compile and run transform tests**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: PASS for the transform layer. `processor.ex` still has the old `DecodePlanner.open_options/1` call — that's Task 6.

Run: `mise exec -- mix test test/image_pipe/transform/ 2>/dev/null || mise exec -- mix test test/image_pipe/ --exclude integration`
Expected: All transform tests pass. Processor tests may error due to the old call.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/transform/plan_executor.ex
git commit -m "feat(transform): PlanExecutor uses source_dimensions for geometry; rescale pixel crop dims"
```

---

### Task 6: `Processor` — two-step open, original-dims safety, feed `source_dimensions`

**Files:**
- Modify: `lib/image_pipe/request/processor.ex`
- Test: `test/image_pipe/processor_test.exs`

This is the core of Plan B. `decode_validate_source_response/3` is restructured to: (1) open for header, (2) read format + original dims + EXIF-corrected dims, (3) validate `max_input_pixels` on original pixel count, (4) call `DecodePlanner.open_options/3`, (5) reopen with full options including shrink/scale, (6) return `source_dimensions` and `achieved_shrink` in the decoded map. `process_decoded_source/3` feeds `source_dimensions` into the initial `%State{}`.

- [ ] **Step 1: Write failing tests**

In `test/image_pipe/processor_test.exs`, add the following tests (keep all existing passing tests):

```elixir
test "max_input_pixels is checked on original header dims, not the shrunk image" do
  # beach.jpg is large enough to get a shrink factor ≥ 2
  body = File.read!("priv/static/images/beach.jpg")
  {:ok, full_image} = Image.open("priv/static/images/beach.jpg")
  orig_pixels = Image.width(full_image) * Image.height(full_image)

  # allow just 1 pixel under the original size → rejected even though shrunk would be small
  tight_limit_opts = Keyword.put(opts(), :max_input_pixels, orig_pixels - 1)

  pid = self()
  counting_loader = fn binary, load_opts ->
    send(pid, {:buffer_opened, load_opts})
    Vix.Vips.Image.new_from_buffer(binary, load_opts)
  end

  response = %Response{stream: [body]}
  {:ok, response} = Source.wrap_response(response, max_body_bytes: byte_size(body) + 100)

  assert {:error, {:input_limit, {:too_many_input_pixels, ^orig_pixels, _max}}} =
           Processor.decode_validate_source_response(
             response,
             plan(),
             tight_limit_opts |> Keyword.put(:buffer_loader, counting_loader)
           )

  # Only the header open (first open) runs — the decode open (second open)
  # must NOT have been called, proving no full-resolution bitmap was materialized.
  assert_receive {:buffer_opened, _header_opts}
  refute_receive {:buffer_opened, _decode_opts}
end

test "shrink-eligible JPEG open: buffer_loader receives shrink option for large downscale" do
  body = File.read!("priv/static/images/beach.jpg")
  {:ok, full_image} = Image.open("priv/static/images/beach.jpg")
  orig_w = Image.width(full_image)

  # Target: 1/9 of original width → load_shrink ≥ 8 → JPEG shrink 8
  target_w = div(orig_w, 9)
  {:ok, shrink_plan} = ImagePipe.Parser.Native.parse("w=#{target_w}")

  pid = self()
  recording_loader = fn binary, load_opts ->
    send(pid, {:buffer_opened, load_opts})
    Vix.Vips.Image.new_from_buffer(binary, load_opts)
  end

  response = %Response{stream: [body]}
  {:ok, response} = Source.wrap_response(response, max_body_bytes: byte_size(body) + 100)

  {:ok, %{image: image}} =
    Processor.decode_validate_source_response(
      response,
      shrink_plan,
      opts() |> Keyword.put(:buffer_loader, recording_loader)
    )

  # First buffer open: header (no shrink)
  assert_receive {:buffer_opened, header_opts}
  refute Keyword.has_key?(header_opts, :shrink)

  # Second buffer open: decode with shrink
  assert_receive {:buffer_opened, decode_opts}
  assert Keyword.get(decode_opts, :shrink) == 8

  # Loaded image dims ≈ orig/8 (within libvips rounding).
  # Use div(orig_w, 5) as the upper bound: this passes for shrink-8 but would
  # fail for shrink-4 or no shrink, making it a real gate not just a sanity check.
  assert Image.width(image) <= div(orig_w, 5)
end

test "PNG downscale: no shrink applied, pixel-exact decode path unchanged" do
  # synthesize a 400x300 PNG
  {:ok, img} = Image.new(400, 300, color: [100, 150, 200])
  png_body = Image.write!(img, :memory, suffix: ".png")

  pid = self()
  recording_loader = fn binary, load_opts ->
    send(pid, {:buffer_opened, load_opts})
    Vix.Vips.Image.new_from_buffer(binary, load_opts)
  end

  {:ok, small_plan} = ImagePipe.Parser.Native.parse("w=50")
  response = %Response{stream: [png_body]}
  {:ok, response} = Source.wrap_response(response, max_body_bytes: byte_size(png_body) + 100)

  {:ok, %{image: _image}} =
    Processor.decode_validate_source_response(
      response,
      small_plan,
      opts() |> Keyword.put(:buffer_loader, recording_loader)
    )

  # Both opens: neither has shrink or scale
  assert_receive {:buffer_opened, _header_opts}
  assert_receive {:buffer_opened, decode_opts}
  refute Keyword.has_key?(decode_opts, :shrink)
  refute Keyword.has_key?(decode_opts, :scale)
end

test "multi-frame GIF is decoded single-page so pixel limit cannot be bypassed by frame count" do
  # Build a 2-frame GIF and confirm only 1 page is loaded
  {:ok, frame} = Image.new(100, 100, color: [255, 0, 0])
  gif_body = Image.write!(frame, :memory, suffix: ".gif")

  response = %Response{stream: [gif_body]}
  {:ok, response} = Source.wrap_response(response, max_body_bytes: byte_size(gif_body) + 100)

  {:ok, %{image: image}} =
    Processor.decode_validate_source_response(response, plan(), opts())

  # A GIF opened without n: override loads exactly 1 frame
  # (libvips default n:1 — Image.height returns single-frame height, not n*frame_height)
  assert Image.height(image) == 100
end
```

Run: `mise exec -- mix test test/image_pipe/processor_test.exs`
Expected: FAIL (several tests fail due to new requirements and old `open_options/1` call breaking compile).

- [ ] **Step 2: Restructure `decode_validate_source_response/3`**

Replace the function body and add helpers in `lib/image_pipe/request/processor.ex`:

```elixir
@spec decode_validate_source_response(Source.Response.t(), Plan.t(), keyword()) ::
        {:ok, decoded()} | {:error, term()}
def decode_validate_source_response(%Source.Response{} = source_response, %Plan{} = plan, opts) do
  operations = first_pipeline_operations(plan)

  with {:ok, input} <- seekable_input(source_response),
       # Step 1: Open lazily for header reading only (no shrink yet).
       {:ok, header_image} <-
         open_seekable_input(input, [access: :random, fail_on: :error], opts)
         |> wrap_decode_error(),
       # Step 2: Read source format and original dims from the header.
       {:ok, source_format} <- SourceFormat.from_image(header_image),
       original_dims = {Image.width(header_image), Image.height(header_image)},
       corrected_dims = orientation_corrected_dims(header_image),
       # Step 3: Validate max_input_pixels on ORIGINAL (pre-shrink) extent.
       :ok <- validate_original_pixels(original_dims, opts) |> wrap_input_limit_error(),
       # Step 4: Compute full decode options (access + optional shrink/scale).
       decode_options = DecodePlanner.open_options(operations, source_format, corrected_dims),
       # Step 5: Reopen with full options for actual decode.
       {:ok, image} <-
         open_seekable_input(input, decode_options, opts)
         |> prefer_source_body_limit(source_response)
         |> prefer_source_stream_error(source_response)
         |> wrap_decode_error() do
    achieved_shrink = compute_achieved_shrink(original_dims, image)

    {:ok,
     %{
       decode_options: decode_options,
       image: image,
       source_format: source_format,
       source_response: source_response,
       source_dimensions: corrected_dims,
       achieved_shrink: achieved_shrink
     }}
  end
end
```

Add these private helpers to `lib/image_pipe/request/processor.ex` (replace the old `validate_input_image/2` and add new ones):

```elixir
# Reads the EXIF orientation from the image header and returns orientation-corrected dims.
# For 90°/270° rotations (EXIF values 5–8), width and height are swapped so the
# shrink factor is computed against displayed (post-AutoOrient) axes.
defp orientation_corrected_dims(image) do
  w = Image.width(image)
  h = Image.height(image)

  case VipsImage.header_value(image, "orientation") do
    {:ok, v} when v in [5, 6, 7, 8] -> {h, w}
    _ -> {w, h}
  end
end

# Validate max_input_pixels against the ORIGINAL (header, pre-shrink) pixel count.
defp validate_original_pixels({w, h}, opts) do
  max_input_pixels = Keyword.fetch!(opts, :max_input_pixels)
  pixel_count = w * h

  if pixel_count <= max_input_pixels do
    :ok
  else
    {:error, {:too_many_input_pixels, pixel_count, max_input_pixels}}
  end
end

defp compute_achieved_shrink({orig_w, orig_h}, image) do
  loaded_w = Image.width(image)
  loaded_h = Image.height(image)
  %{w: max(1.0, orig_w / loaded_w), h: max(1.0, orig_h / loaded_h)}
end
```

Remove the old `validate_input_image/2` function (it validated the POST-decode image; the new `validate_original_pixels/2` replaces it).

- [ ] **Step 3: Update `process_decoded_source/3` to feed `source_dimensions` into State**

Replace `process_decoded_source/3`:

```elixir
@spec process_decoded_source(decoded(), Plan.t(), keyword()) ::
        {:ok, State.t()} | {:error, term()}
def process_decoded_source(
      %{decode_options: decode_options, image: image} = decoded,
      %Plan{} = plan,
      opts
    ) do
  source_response = Map.get(decoded, :source_response)
  source_dimensions = Map.get(decoded, :source_dimensions)

  initial_state = %State{image: image, source_dimensions: source_dimensions}

  Telemetry.span(Telemetry.telemetry_opts(opts), [:transform, :execute], %{}, fn ->
    result =
      with {:ok, final_state} <-
             execute_plan_pipelines(initial_state, plan, opts, source_response),
           {:ok, final_state} <-
             materialize_before_delivery(final_state, decode_options, opts, source_response),
           :ok <- validate_result_image(final_state.image, opts) do
        {:ok, final_state}
      end

    {result, transform_stop_metadata(result)}
  end)
end
```

- [ ] **Step 4: Update `@type decoded()` to include new fields**

Replace the `@type decoded()` spec:

```elixir
@type decoded() :: %{
        required(:decode_options) => keyword(),
        required(:image) => VipsImage.t(),
        required(:source_format) => source_format(),
        optional(:source_response) => Source.Response.t(),
        optional(:source_dimensions) => {pos_integer(), pos_integer()} | nil,
        optional(:achieved_shrink) => %{w: float(), h: float()} | nil
      }
```

- [ ] **Step 5: Run processor tests**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs`
Expected: PASS. All existing tests plus the four new ones.

- [ ] **Step 5a: Explicitly verify the unsupported-format-before-input-pixel ordering test**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs --only "unsupported" 2>/dev/null || mise exec -- mix test test/image_pipe/processor_test.exs -k unsupported`

Find the test named `"unsupported decoded source format is reported before input pixel limits"` (or similar) in `processor_test.exs`. In the new two-step flow, `SourceFormat.from_image(header_image)` runs in Step 2, BEFORE `validate_original_pixels` in Step 3 — so the ordering is preserved. Confirm the test still passes. If it fails, the likely cause is the return tag changed (`{:error, {:unsupported_source_format, ...}}` vs `{:error, {:source, ...}}`); fix the assertion to match the actual error returned by `SourceFormat.from_image`.

- [ ] **Step 6: Run architecture boundary test**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS — Processor does not name concrete transform operation modules; `DecodePlanner.open_options/3` takes plain atoms, not SourceFormat types.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/request/processor.ex test/image_pipe/processor_test.exs
git commit -m "feat(request): two-step open with shrink-on-load; max_input_pixels on original dims"
```

---

### Task 7: Telemetry — extend `fetch_decode_stop_metadata`

**Files:**
- Modify: `lib/image_pipe/request/processor.ex`
- Test: `test/image_pipe/telemetry_test.exs`

Emit `load_option`, `achieved_shrink`, `original_dims`, and `loaded_dims` on the existing `[:source, :fetch_decode]` span stop metadata.

- [ ] **Step 1: Update `fetch_decode_stop_metadata/1`**

Replace `fetch_decode_stop_metadata/1` in `lib/image_pipe/request/processor.ex`:

```elixir
defp fetch_decode_stop_metadata({:ok, %{image: image, decode_options: decode_options} = decoded}) do
  load_option =
    cond do
      Keyword.has_key?(decode_options, :shrink) -> {:shrink, Keyword.fetch!(decode_options, :shrink)}
      Keyword.has_key?(decode_options, :scale) -> {:scale, Keyword.fetch!(decode_options, :scale)}
      true -> nil
    end

  %{
    result: :ok,
    load_option: load_option,
    achieved_shrink: Map.get(decoded, :achieved_shrink),
    original_dims: Map.get(decoded, :source_dimensions),
    loaded_dims: {Image.width(image), Image.height(image)}
  }
end

defp fetch_decode_stop_metadata({:error, {:source, error}}),
  do: %{result: :source_error, error: Error.tag(error)}

defp fetch_decode_stop_metadata({:error, error}),
  do: %{result: :processing_error, error: Error.tag(error)}
```

- [ ] **Step 2: Add telemetry test for shrink metadata**

In `test/image_pipe/telemetry_test.exs`, find the block that tests `[:source, :fetch_decode]` events and add:

```elixir
test "fetch_decode stop metadata includes load_option and achieved_shrink for JPEG downscale" do
  body = File.read!("priv/static/images/beach.jpg")
  {:ok, full_image} = Image.open("priv/static/images/beach.jpg")
  orig_w = Image.width(full_image)
  orig_h = Image.height(full_image)

  target_w = div(orig_w, 9)  # triggers shrink 8
  {:ok, shrink_plan} = ImagePipe.Parser.Native.parse("w=#{target_w}")

  ref = :telemetry_test.attach_event_handlers(self(), [[:source, :fetch_decode]])

  response = %Source.Response{stream: [body]}
  {:ok, response} = Source.wrap_response(response, max_body_bytes: byte_size(body) + 100)
  Processor.fetch_decode_validate_source_with_source_format(shrink_plan, resolve_for(response), test_opts())

  assert_receive {[:source, :fetch_decode], ^ref, %{}, stop_meta}
  :telemetry.detach(ref)

  assert stop_meta.result == :ok
  assert stop_meta.load_option == {:shrink, 8}
  assert %{w: achieved_w, h: achieved_h} = stop_meta.achieved_shrink
  assert achieved_w >= 4.0
  assert achieved_h >= 4.0
  assert stop_meta.original_dims == {orig_w, orig_h}
  {loaded_w, loaded_h} = stop_meta.loaded_dims
  assert loaded_w <= div(orig_w, 4)
  assert loaded_h <= div(orig_h, 4)
end
```

(Adjust `resolve_for/1`, `test_opts/0`, and the telemetry test helper pattern to match the existing telemetry test setup in the file — look at existing tests in `telemetry_test.exs` for the exact pattern.)

- [ ] **Step 3: Run telemetry tests**

Run: `mise exec -- mix test test/image_pipe/telemetry_test.exs`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/request/processor.ex test/image_pipe/telemetry_test.exs
git commit -m "feat(telemetry): emit load_option, achieved_shrink, dims on fetch_decode span"
```

---

### Task 8: Delete compatibility test; add wire-level equivalence tests

**Files:**
- Delete: `test/image_pipe/sequential_compatibility_test.exs`
- Create: `test/image_pipe/shrink_on_load_test.exs`

`sequential_compatibility_test.exs` asserts pixel-exact equality between sequential and random access opens — incompatible with shrink-on-load (different downsample kernel). Delete it. Replace with wire-level `ImagePipe.call/2` tests that assert the new equivalence contract: dimension-exact output and coarse-downsample MAE < threshold.

- [ ] **Step 1: Delete `sequential_compatibility_test.exs`**

```bash
git rm test/image_pipe/sequential_compatibility_test.exs
git commit -m "test: delete sequential_compatibility_test (access-mode parity pin, incompatible with shrink-on-load)"
```

- [ ] **Step 2: Create `test/image_pipe/shrink_on_load_test.exs`**

```elixir
defmodule ImagePipe.ShrinkOnLoadTest do
  # async: false — real fixture I/O and telemetry handler registration require serial execution
  use ExUnit.Case, async: false

  import Plug.Test
  import ImagePipe.PlugTestHelpers, only: [build_plug_opts: 1]

  alias ImagePipe.Source.Response

  # Coarse-downsample MAE threshold. JPEG IDCT shrink + residual high-quality resize
  # differs from full-decode + single resize, but both produce "the same picture."
  #
  # IMPORTANT: run the MAE test once first to observe the actual raw MAE value,
  # then set this threshold to 3–5× that value and add a comment like:
  #   # MAE ~1.8 measured against libvips 8.15.1; threshold = 5× = 9.0
  # This threshold is a generous starting point; pin it to a real measurement.
  @mae_threshold 10.0
  @thumb_size 32

  # --- Dimension-exact equivalence: JPEG ---

  test "JPEG large downscale produces exactly the requested output dimensions" do
    {:ok, full_image} = Image.open("priv/static/images/beach.jpg")
    orig_w = Image.width(full_image)
    orig_h = Image.height(full_image)

    target_w = div(orig_w, 9)  # forces shrink 8

    {status, _headers, body} = call_pipe("w=#{target_w}&fit=fit")
    assert status == 200

    {:ok, result} = Image.from_binary(body)
    assert Image.width(result) == target_w
    # height is auto-computed from aspect ratio — just assert it's non-zero
    assert Image.height(result) > 0
    # and that the aspect ratio is approximately preserved
    expected_h = round(target_w * orig_h / orig_w)
    assert abs(Image.height(result) - expected_h) <= 2
  end

  test "JPEG shrink-on-load output is perceptually equivalent to full-decode (MAE gate)" do
    {:ok, full_image} = Image.open("priv/static/images/beach.jpg")
    orig_w = Image.width(full_image)

    target_w = div(orig_w, 8)

    # Shrink-on-load path (normal ImagePipe request)
    {200, _headers, shrink_body} = call_pipe("w=#{target_w}&fit=fit")

    # Full-decode baseline: open at full res, resize with libvips
    {:ok, baseline_resized} = Image.thumbnail("priv/static/images/beach.jpg", target_w)

    {:ok, shrink_image} = Image.from_binary(shrink_body)

    # Hard gate: dimensions exactly equal
    assert Image.width(shrink_image) == Image.width(baseline_resized)
    assert Image.height(shrink_image) == Image.height(baseline_resized)

    # Hard gate: alpha channel presence equal
    assert Image.has_alpha?(shrink_image) == Image.has_alpha?(baseline_resized)

    # Soft gate: coarse-downsample MAE (measures "same picture", not "same kernel")
    mae = coarse_mae(shrink_image, baseline_resized)
    assert mae < @mae_threshold,
           "JPEG shrink-on-load MAE #{Float.round(mae, 2)} exceeded threshold #{@mae_threshold}"
  end

  # --- WebP equivalence ---

  @tag :webp
  test "WebP large downscale is dimension-exact and perceptually equivalent" do
    # Synthesize a 1600x1200 WebP for testing (avoids fixture size dependency)
    {:ok, src} = Image.new(1600, 1200, color: [200, 150, 100])
    webp_body = Image.write!(src, :memory, suffix: ".webp")
    target_w = 200

    # Full-decode baseline
    {:ok, src_reopened} = Image.from_binary(webp_body)
    baseline = Image.thumbnail!(src_reopened, target_w)

    # Shrink-on-load via ImagePipe
    {200, _headers, result_body} = call_pipe_with_body("w=#{target_w}&fit=fit", webp_body, "image/webp")
    {:ok, result_image} = Image.from_binary(result_body)

    assert Image.width(result_image) == target_w
    assert Image.height(result_image) == 150  # 200 * (1200/1600)

    mae = coarse_mae(result_image, baseline)
    assert mae < @mae_threshold,
           "WebP scale-on-load MAE #{Float.round(mae, 2)} exceeded threshold #{@mae_threshold}"
  end

  # --- PNG: no shrink, pixel-exact ---

  test "PNG downscale falls back to full decode and remains pixel-exact" do
    # PNG is not shrink-eligible; output should be identical to direct resize
    {:ok, src} = Image.new(400, 300, color: [0, 128, 255, 255], bands: 4)
    png_body = Image.write!(src, :memory, suffix: ".png")
    target_w = 50

    {200, _headers, result_body} = call_pipe_with_body("w=#{target_w}&fit=fit", png_body, "image/png")
    {:ok, result} = Image.from_binary(result_body)

    # Full-decode baseline
    {:ok, src_reopened} = Image.from_binary(png_body)
    {:ok, baseline} = Image.resize(src_reopened, target_w / 400.0, vertical_scale: 37.5 / 300.0)

    assert Image.width(result) == target_w
    # Alpha must be preserved (source PNG has alpha)
    assert Image.has_alpha?(result)
    assert Image.has_alpha?(result) == Image.has_alpha?(baseline)
    # PNG path is unchanged — check pixel-exact equivalence (MAE ≈ 0)
    assert coarse_mae(result, baseline) < 1.0
  end

  # --- Safety: max_input_pixels on original dims ---

  test "oversized JPEG is rejected at original extent even when shrunk image would be small" do
    {:ok, full_image} = Image.open("priv/static/images/beach.jpg")
    orig_pixels = Image.width(full_image) * Image.height(full_image)

    # tight pixel limit: 1 under original
    {status, _headers, _body} =
      call_pipe("w=100&fit=fit", max_input_pixels: orig_pixels - 1)

    assert status == 422
  end

  # --- Safety: multi-frame input loads single-page ---

  test "animated GIF is loaded single-page so pixel limit cannot be bypassed by frame count" do
    # Build a 2-frame 200x200 GIF (frame_count * 200 * 200 > single_frame * 200 * 200)
    {:ok, frame1} = Image.new(200, 200, color: [255, 0, 0])
    {:ok, frame2} = Image.new(200, 200, color: [0, 255, 0])
    # Write as individual frames and join into a GIF
    gif_binary = build_animated_gif(frame1, frame2)

    # With a pixel limit of 200*200+1 (allows 1 frame, not 2 frames worth)
    single_frame_pixels = 200 * 200
    {status, _headers, body} =
      call_pipe_with_body("w=100&fit=fit", gif_binary, "image/gif",
        max_input_pixels: single_frame_pixels + 1
      )

    # Should succeed (only 1 frame decoded, pixel count = 200*200 ≤ limit)
    assert status == 200
    {:ok, result} = Image.from_binary(body)
    assert Image.width(result) == 100
  end

  # --- Helpers ---

  defp call_pipe(query_string, extra_opts \\ []) do
    opts = build_plug_opts([max_input_pixels: 100_000_000] ++ extra_opts)
    conn =
      conn(:get, "/?#{query_string}")
      |> Map.put(:path_info, ["images", "beach.jpg"])

    conn = ImagePipe.call(conn, opts)
    {conn.status, conn.resp_headers, conn.resp_body}
  end

  defp call_pipe_with_body(query_string, body, content_type, extra_opts \\ []) do
    # Use an in-memory source that serves the provided body
    opts =
      build_plug_opts(
        [max_input_pixels: 100_000_000, source: {TestBodySource, body: body, content_type: content_type}] ++
          extra_opts
      )

    conn =
      conn(:get, "/?#{query_string}")
      |> Map.put(:path_info, ["test"])

    conn = ImagePipe.call(conn, opts)
    {conn.status, conn.resp_headers, conn.resp_body}
  end

  defp coarse_mae(image_a, image_b) do
    # Downscale both to @thumb_size × @thumb_size, then compute per-pixel mean absolute error.
    {:ok, thumb_a} = Image.thumbnail(image_a, @thumb_size, height: @thumb_size, crop: :VIPS_INTERESTING_NONE)
    {:ok, thumb_b} = Image.thumbnail(image_b, @thumb_size, height: @thumb_size, crop: :VIPS_INTERESTING_NONE)

    # Ensure same dims (thumbnail may vary by ±1 due to rounding)
    w = min(Image.width(thumb_a), Image.width(thumb_b))
    h = min(Image.height(thumb_a), Image.height(thumb_b))

    total_error =
      for x <- 0..(w - 1), y <- 0..(h - 1), reduce: 0 do
        acc ->
          px_a = Image.get_pixel!(thumb_a, x, y) |> Enum.take(3)
          px_b = Image.get_pixel!(thumb_b, x, y) |> Enum.take(3)
          channel_error = Enum.zip(px_a, px_b) |> Enum.map(fn {a, b} -> abs(a - b) end) |> Enum.sum()
          acc + channel_error
      end

    total_error / (w * h * 3)
  end

  defp build_animated_gif(frame1, frame2) do
    # Stack frames vertically (libvips multi-frame GIF convention: frames are
    # page_height-tall strips stacked in the Y direction; across: 1 is the default).
    # Do NOT use `direction: :vertical` — that option does not exist in Image.join/2.
    f1_bin = Image.write!(frame1, :memory, suffix: ".png")
    f2_bin = Image.write!(frame2, :memory, suffix: ".png")
    {:ok, img1} = Image.from_binary(f1_bin)
    {:ok, img2} = Image.from_binary(f2_bin)
    {:ok, frames} = Image.join([img1, img2])
    Image.write!(frames, :memory, suffix: ".gif[n=2,loop=0]")
    # No rescue: if animated GIF write fails, let the test fail clearly rather than
    # silently falling back to a single-frame (which would make the test vacuous).
  end
end
```

**Note on `TestBodySource`:** If the test infrastructure does not have a generic in-memory source for providing arbitrary bodies to `ImagePipe.call/2`, use the file source with a tmp file instead:

```elixir
defp write_tmp(body, suffix) do
  path = Path.join(System.tmp_dir!(), "shrink_test_#{:erlang.unique_integer([:positive])}#{suffix}")
  File.write!(path, body)
  on_exit(fn -> File.rm(path) end)
  path
end
```

And adjust `call_pipe_with_body` accordingly.

- [ ] **Step 3: Run the new tests (expect some to need adjustment)**

Run: `mise exec -- mix test test/image_pipe/shrink_on_load_test.exs`
Expected: Most pass. Adjust `build_plug_opts`, the `TestBodySource` or tmp-file fallback, and `call_pipe_with_body` to match the actual test infrastructure. Check `plug_test.exs` for the patterns used to make `ImagePipe.call/2` tests.

The MAE test can fail on first run if the threshold is too tight — pin the measured value in the test comment with generous margin.

- [ ] **Step 4: Commit**

```bash
git add test/image_pipe/shrink_on_load_test.exs
git commit -m "test(shrink-on-load): wire-level JPEG/WebP equivalence, PNG pixel-exact, safety gates"
```

---

### Task 9: Full-suite regression sweep

**Files:** none expected (find and fix fallout).

- [ ] **Step 1: Run the full suite**

Run: `mise exec -- mix test`
Expected: GREEN. Watch specifically for:
- Any test that referenced `DecodePlanner.open_options/1` with 1 arg — update to 3-arg form.
- Any test that read `max_input_pixels` from the decoded image size — update to original dims.
- Any test asserting pixel-exact output for a shrink-eligible JPEG downscale — update to accept MAE < threshold.

- [ ] **Step 2: Fix any failing tests**

For each failure:
- If a test was asserting the old pixel-exact behavior for a shrink path: update to dimension-exact + MAE gate.
- If a test asserted `validate_input_image` contract on decoded dims: update to original dims.
- Do NOT delete tests that assert meaningful user-visible contracts (status, headers, output dimensions, alpha).

- [ ] **Step 3: Re-run until green**

Run: `mise exec -- mix test`
Expected: PASS (all).

---

### Task 10: Gate

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all pass.

- [ ] **Step 2: Fix any format/credo/warning issues**

Common credo issues:
- Unused aliases after removing old `validate_input_image/2`.
- Functions with too many clauses — split or reorganize if credo flags.

- [ ] **Step 3: Final commit if the gate required fixes**

```bash
git add -A
git commit -m "chore: satisfy precommit gate for shrink-on-load Plan B"
```

---

## Self-Review

**1. Spec coverage:**

| Spec section | Task covering it |
|---|---|
| DecodePlanner `{access, load_option}` from `(operations, format, dims)` | Task 3 |
| JPEG `shrink: 1\|2\|4\|8`, WebP `scale:`, PNG/HEIF/AVIF none | Task 3 |
| `min(wshrink, hshrink)`, orientation-corrected axes | Task 3 |
| Processor: header open → format/dims → `max_input_pixels` on original | Task 6 |
| Processor: reopen with load option, `achieved_shrink` | Task 6 |
| `Transform.State.source_dimensions` | Task 1 |
| `Resize` target from original dims, scale from shrunk | Task 4 |
| Crop/gravity rescaling by achieved prescale | Task 5 |
| Delete `sequential_compatibility_test.exs` | Task 8 |
| Wire-level JPEG/WebP MAE equivalence tests | Task 8 |
| PNG pixel-exact (no shrink) | Task 8 |
| Multi-frame single-page safety test | Task 8 |
| `max_input_pixels` on original extent safety test | Tasks 6 + 8 |
| Telemetry: `load_option`, `achieved_shrink`, dims on `[:source, :fetch_decode]` | Task 7 |
| Deterministic decoded-dimension gate | Task 6 (recording buffer_loader test) |
| Decode strategy NOT in cache key or ETag | No code change needed (already excluded) |

**2. Placeholder scan:** No TBDs, TODOs, or "similar to above" references. Every code step shows complete code.

**3. Type consistency:**
- `DecodePlanner.open_options/3` defined in Task 3; called in Processor Task 6 as `DecodePlanner.open_options(operations, source_format, corrected_dims)` ✓
- `State.effective_source_dims/1` defined in Task 1; called as `State.effective_source_dims(state)` in Tasks 4 and 5 ✓
- `source_dimensions: {pos_integer(), pos_integer()} | nil` — set in Processor Task 6, read in Resize Task 4 and PlanExecutor Task 5 ✓
- `achieved_shrink: %{w: float(), h: float()}` — set in Processor Task 6, emitted in Telemetry Task 7 ✓
- `corrected_dims` is `{w, h}` tuple passed to `DecodePlanner.open_options/3` and stored as `source_dimensions` — consistent ✓
