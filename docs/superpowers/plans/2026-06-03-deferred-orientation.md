# Deferred Orientation (#146) + Shrink-Through-Crop (#151) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace eager head-of-pipeline EXIF/user orientation with a *pending* rotate/flip carried on `Transform.State`, applied (flushed) late — fused with realizing the resized image — with pre-flush crop/resize compensated; output stays byte-identical to today (perf parity). Then (Slice B) let shrink-on-load proceed through a preceding crop.

**Architecture:** EXIF auto-orient stops being a `Plan.Operation.AutoOrient` pipeline op and becomes a top-level `Plan.auto_rotate` boolean. `PlanExecutor` (which interleaves build+execute per op with the live image) seeds a `pending_orientation` from the source EXIF tag (first pipeline only, when `auto_rotate`), folds user `Rotate`/`Flip` into it, compensates pre-flush crop/resize, and flushes via the existing materialize chokepoint. A new `Transform.OrientationFlush` owns the replay; a new `Transform.Orientation` owns the coordinate compensation (gravity remap + dim/requested-dim swap). Per-pipeline flush; `materialize_before_delivery` is the backstop.

**Tech Stack:** Elixir, `Vix.Vips.Image` (libvips via the `image` lib), ExUnit + StreamData. Run everything via `mise exec -- mix ...`. Focused test: `mise exec -- mix test <path>`. Full gate: `mise run precommit` (`mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`).

**Spec:** `docs/superpowers/specs/2026-06-03-deferred-orientation-design.md` (v3, reviewed).

**Critical conventions discovered in the codebase:**
- Two AutoOrient modules today: the **plan op** `ImagePipe.Plan.Operation.AutoOrient` (removed by this plan) and the **executable op** `ImagePipe.Transform.Operation.AutoOrient` (its autorotate logic moves into `OrientationFlush`).
- All flush entry points route through `Materializer.materialize/1` (3 call sites: `Chain.maybe_materialize`, the executable AutoOrient self-materialize — being removed, and `processor` delivery backstop via `materialize/2`). Making `materialize/1` flush-aware covers them all.
- Materialize failures must surface as `{:decode, _}` (→ 415). `Chain` wraps to `{:materialize_error, _}` → `processor` `classify_materialize_error/1` maps to `{:decode, _}`.
- EXIF orientation read via `Vix.Vips.Image.header_value(image, "orientation")` → 1–8 (default 1).
- Test fixtures set orientation with `Image.set_orientation!(image, n)`; pixel comparison samples positions and compares `Image.get_pixel!`.

---

## File Structure

**New files:**
- `lib/image_pipe/transform/pending_orientation.ex` — typed struct for pending state (`auto_rotate?`, `exif_angle`, `exif_flip_x`, `user_angle`, `user_flip_x`, `user_flip_y`) + the EXIF `orientation(1..8) → {angle, flip_x}` mapping and `user`-folding helpers. Pure.
- `lib/image_pipe/transform/orientation_flush.ex` — `flush/1`: replay (autorotate when `auto_rotate?` → user rotate → user flip) + `copy_memory` + clear pending. The one place orientation pixels are applied.
- `lib/image_pipe/transform/orientation.ex` — pure coordinate compensation: `RotateAndFlip` gravity-spec port (remap + offset), crop dim swap, and resize requested-dim swap. The single home for orientation x/y transposition (called only by `PlanExecutor`).
- Tests: `test/image_pipe/transform/pending_orientation_test.exs`, `orientation_flush_test.exs`, `orientation_test.exs`.

**Modified files:**
- `lib/image_pipe/transform/state.ex` — add `pending_orientation` field.
- `lib/image_pipe/transform/materializer.ex` — `materialize/1` becomes flush-aware.
- `lib/image_pipe/transform/plan_executor.ex` — seed pending, fold user rotate/flip, compensate crop/resize, force flush after resize / before region crop, per-pipeline flush; drop `PlanAutoOrient` clause.
- `lib/image_pipe/transform/decode_planner.ex` — `open_options/4 → /5` (add `auto_rotate`), replace `%AutoOrient{}` chain scan.
- `lib/image_pipe/request/processor.ex` — pass `auto_rotate` to `open_options`; pass per-pipeline seed signal to `Transform.execute_plan`.
- `lib/image_pipe/plan.ex` — add `auto_rotate` field; drop `Operation.AutoOrient` export.
- `lib/image_pipe/plan/operation.ex` — drop AutoOrient alias/union/constructor/`semantic?` clause.
- `lib/image_pipe/plan/key_data.ex` — drop `data(%AutoOrient{})`.
- `lib/image_pipe/cache/key.ex` — emit `auto_rotate` in `plan_material/2`.
- `lib/image_pipe/parser/imgproxy/{options.ex,plan_builder.ex,parsed_request.ex}` + `imgproxy.ex` — surface a single `auto_rotate` boolean; stop emitting the AutoOrient op.
- `lib/image_pipe/transform.ex` — drop `Operation.AutoOrient` export.
- `test/image_pipe/architecture_boundary_test.exs` — drop `:AutoOrient` plan-op entries.

**Deleted files:**
- `lib/image_pipe/plan/operation/auto_orient.ex`
- `lib/image_pipe/transform/operation/auto_orient.ex` (logic absorbed into `OrientationFlush`)
- `test/image_pipe/transform/operation/auto_orient_materialize_test.exs` + `auto_orient_test.exs` (coverage moves to `orientation_flush_test.exs`)

---

# SLICE A — Deferred orientation (#146)

Ordering: build the inert machinery first (T1–T4), add the inert boolean plumbing (T5–T7), repoint decode (T8), then the coordinated cutover (T9), then cleanup (T10) and the gate tests (T11). The system stays green through T8 (the boolean is set but unused; the AutoOrient op still does the orientation). T9 is the single behavior-preserving cutover, verified by the libvips-reference gate and wire conformance.

## Task 1: `PendingOrientation` struct + EXIF mapping

**Files:**
- Create: `lib/image_pipe/transform/pending_orientation.ex`
- Test: `test/image_pipe/transform/pending_orientation_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/transform/pending_orientation_test.exs
defmodule ImagePipe.Transform.PendingOrientationTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.PendingOrientation, as: PO

  describe "from_exif/2" do
    test "maps EXIF orientation 1..8 to angle + horizontal mirror" do
      assert PO.from_exif(1, true) == %PO{auto_rotate?: true, exif_angle: 0, exif_flip_x: false}
      assert PO.from_exif(2, true) == %PO{auto_rotate?: true, exif_angle: 0, exif_flip_x: true}
      assert PO.from_exif(3, true) == %PO{auto_rotate?: true, exif_angle: 180, exif_flip_x: false}
      assert PO.from_exif(4, true) == %PO{auto_rotate?: true, exif_angle: 180, exif_flip_x: true}
      assert PO.from_exif(5, true) == %PO{auto_rotate?: true, exif_angle: 90, exif_flip_x: true}
      assert PO.from_exif(6, true) == %PO{auto_rotate?: true, exif_angle: 90, exif_flip_x: false}
      assert PO.from_exif(7, true) == %PO{auto_rotate?: true, exif_angle: 270, exif_flip_x: true}
      assert PO.from_exif(8, true) == %PO{auto_rotate?: true, exif_angle: 270, exif_flip_x: false}
    end

    test "auto_rotate? false yields no EXIF contribution regardless of tag" do
      assert PO.from_exif(6, false) == %PO{auto_rotate?: false, exif_angle: 0, exif_flip_x: false}
    end
  end

  describe "fold_rotate/2 and fold_flip/2" do
    test "accumulates user rotate additively mod 360" do
      po = %PO{user_angle: 90} |> PO.fold_rotate(270)
      assert po.user_angle == 0
    end

    test "folds horizontal/vertical/both flips" do
      assert PO.fold_flip(%PO{}, :horizontal).user_flip_x == true
      assert PO.fold_flip(%PO{}, :vertical).user_flip_y == true
      both = PO.fold_flip(%PO{}, :both)
      assert both.user_flip_x == true and both.user_flip_y == true
    end
  end

  describe "quarter_turn?/1" do
    test "true iff combined exif+user angle is 90 or 270 mod 180" do
      assert PO.quarter_turn?(%PO{exif_angle: 90, user_angle: 0}) == true
      assert PO.quarter_turn?(%PO{exif_angle: 90, user_angle: 90}) == false
      assert PO.quarter_turn?(%PO{exif_angle: 0, user_angle: 270}) == true
      assert PO.quarter_turn?(%PO{exif_angle: 180, user_angle: 0}) == false
    end
  end
end
```

- [ ] **Step 2: Run it; expect failure (module undefined)**

Run: `mise exec -- mix test test/image_pipe/transform/pending_orientation_test.exs`
Expected: FAIL — `ImagePipe.Transform.PendingOrientation` is undefined.

- [ ] **Step 3: Implement the struct + helpers**

```elixir
# lib/image_pipe/transform/pending_orientation.ex
defmodule ImagePipe.Transform.PendingOrientation do
  @moduledoc false
  # Deferred orientation carried on Transform.State: EXIF auto-orient ∘ user
  # rotate ∘ user flip, applied late by Transform.OrientationFlush. Pure data +
  # the EXIF-tag → (angle, horizontal-mirror) mapping. Verify the mapping against
  # `local/imgproxy-master/processing/prepare.go` (angleFlip): 3/4→180, 5/6→90,
  # 7/8→270; horizontal mirror on 2/4/5/7.

  defstruct auto_rotate?: false,
            exif_angle: 0,
            exif_flip_x: false,
            user_angle: 0,
            user_flip_x: false,
            user_flip_y: false

  @type t :: %__MODULE__{
          auto_rotate?: boolean(),
          exif_angle: 0 | 90 | 180 | 270,
          exif_flip_x: boolean(),
          user_angle: 0 | 90 | 180 | 270,
          user_flip_x: boolean(),
          user_flip_y: boolean()
        }

  @spec from_exif(1..8, boolean()) :: t()
  def from_exif(_orientation, false), do: %__MODULE__{auto_rotate?: false}

  def from_exif(orientation, true) do
    {angle, flip_x} = exif_angle_flip(orientation)
    %__MODULE__{auto_rotate?: true, exif_angle: angle, exif_flip_x: flip_x}
  end

  defp exif_angle_flip(1), do: {0, false}
  defp exif_angle_flip(2), do: {0, true}
  defp exif_angle_flip(3), do: {180, false}
  defp exif_angle_flip(4), do: {180, true}
  defp exif_angle_flip(5), do: {90, true}
  defp exif_angle_flip(6), do: {90, false}
  defp exif_angle_flip(7), do: {270, true}
  defp exif_angle_flip(8), do: {270, false}
  defp exif_angle_flip(_), do: {0, false}

  @spec fold_rotate(t(), 0 | 90 | 180 | 270) :: t()
  def fold_rotate(%__MODULE__{user_angle: a} = po, angle),
    do: %__MODULE__{po | user_angle: rem(a + angle, 360)}

  @spec fold_flip(t(), :horizontal | :vertical | :both) :: t()
  def fold_flip(%__MODULE__{} = po, :horizontal), do: %__MODULE__{po | user_flip_x: not po.user_flip_x}
  def fold_flip(%__MODULE__{} = po, :vertical), do: %__MODULE__{po | user_flip_y: not po.user_flip_y}

  def fold_flip(%__MODULE__{} = po, :both),
    do: %__MODULE__{po | user_flip_x: not po.user_flip_x, user_flip_y: not po.user_flip_y}

  @spec quarter_turn?(t()) :: boolean()
  def quarter_turn?(%__MODULE__{exif_angle: ea, user_angle: ua}), do: rem(ea + ua, 180) == 90

  @doc "True when there is no pixel work to flush (identity orientation)."
  @spec identity?(t()) :: boolean()
  def identity?(%__MODULE__{exif_angle: 0, exif_flip_x: false, user_angle: 0, user_flip_x: false, user_flip_y: false}),
    do: true

  def identity?(%__MODULE__{}), do: false
end
```

- [ ] **Step 4: Run; expect PASS**

Run: `mise exec -- mix test test/image_pipe/transform/pending_orientation_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/pending_orientation.ex test/image_pipe/transform/pending_orientation_test.exs
git commit -m "feat(transform): add PendingOrientation struct + EXIF mapping (#146)"
```

> Note for the implementer: confirm `from_exif/2` against `local/imgproxy-master/processing/prepare.go angleFlip` and the existing wire fixture (orientation 6 ⇒ 90° ⇒ 40×80 storage displays 80×40). If imgproxy's transpose handling for 5/7 differs, fix the mapping and the test together.

## Task 2: `OrientationFlush` — the replay primitive

**Files:**
- Create: `lib/image_pipe/transform/orientation_flush.ex`
- Test: `test/image_pipe/transform/orientation_flush_test.exs`

The flush applies EXIF (via `Image.autorotate`, only when `auto_rotate?`) then user rotate then user flip, then `copy_memory`, then clears pending. Verified against an independent libvips reference (the pattern from the deleted `auto_orient_materialize_test.exs`).

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/transform/orientation_flush_test.exs
defmodule ImagePipe.Transform.OrientationFlushTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.{OrientationFlush, PendingOrientation, State}

  defp marked, do: Image.Draw.rect!(Image.new!(40, 20, color: :white), 0, 0, 4, 4, color: :red)
  defp oriented(base, n), do: Image.set_orientation!(base, n)

  defp sample_positions(size) do
    last = max(size - 1, 0)
    Enum.uniq([0, div(last, 4), div(last, 2), div(last * 3, 4), last])
  end

  defp assert_pixels_match(left, right) do
    assert Image.width(left) == Image.width(right)
    assert Image.height(left) == Image.height(right)

    for x <- sample_positions(Image.width(left)), y <- sample_positions(Image.height(left)) do
      assert Image.get_pixel!(left, x, y) == Image.get_pixel!(right, x, y), "pixel mismatch at (#{x},#{y})"
    end
  end

  # Reference: apply EXIF (autorotate) then user rotate then user flip directly.
  defp reference(base, %PendingOrientation{} = po) do
    img = if po.auto_rotate?, do: elem(Image.autorotate(base) |> ok(), 0), else: base
    img = if po.user_angle != 0, do: Image.rotate!(img, po.user_angle), else: img
    img = if po.user_flip_x, do: Image.flip!(img, :horizontal), else: img
    if po.user_flip_y, do: Image.flip!(img, :vertical), else: img
  end

  defp ok({:ok, v}), do: v

  test "auto_rotate?=true: flush matches autorotate reference for EXIF 1..8, materializes, clears pending" do
    for orientation <- 1..8 do
      base = marked()
      po = PendingOrientation.from_exif(orientation, true)
      state = %State{image: oriented(base, orientation), pending_orientation: po, materialized?: false}

      assert {:ok, %State{} = result} = OrientationFlush.flush(state)
      assert result.materialized? == true
      assert result.pending_orientation == nil
      assert_pixels_match(result.image, reference(oriented(base, orientation), po))
    end
  end

  test "auto_rotate?=false: EXIF tag is NOT applied (ar:0 regression guard), only user rotate" do
    base = marked()
    # Source carries orientation 6, but auto_rotate disabled + user rotate 90.
    po = %PendingOrientation{auto_rotate?: false, user_angle: 90}
    state = %State{image: oriented(base, 6), pending_orientation: po, materialized?: false}

    assert {:ok, %State{} = result} = OrientationFlush.flush(state)
    # Reference applies ONLY the user 90°, never the EXIF tag.
    expected = Image.rotate!(oriented(base, 6), 90)
    assert_pixels_match(result.image, expected)
  end

  # (Materialize-failure → {:materialize_error,_} → {:decode,_} is exercised at the
  # Chain/processor boundary, not here — do not add an `assert true` placeholder.)
end
```

- [ ] **Step 2: Run; expect failure**

Run: `mise exec -- mix test test/image_pipe/transform/orientation_flush_test.exs`
Expected: FAIL — `OrientationFlush` undefined.

- [ ] **Step 3: Implement**

```elixir
# lib/image_pipe/transform/orientation_flush.ex
defmodule ImagePipe.Transform.OrientationFlush do
  @moduledoc false
  # Applies pending orientation pixels late (EXIF ∘ user rotate ∘ user flip),
  # then copy_memory, then clears pending. The single place orientation pixels are
  # written. EXIF is replayed via Image.autorotate ONLY when auto_rotate? is true:
  # autorotate reads the live EXIF tag, so calling it for an ar:0 source that still
  # carries a tag would wrongly apply suppressed EXIF rotation.

  alias ImagePipe.Transform.{PendingOrientation, State}

  @spec flush(State.t()) :: {:ok, State.t()} | {:error, term()}
  def flush(%State{pending_orientation: nil} = state), do: materialize(state)

  def flush(%State{pending_orientation: %PendingOrientation{} = po} = state) do
    with {:ok, image} <- apply_orientation(state.image, po),
         {:ok, image} <- Vix.Vips.Image.copy_memory(image) do
      {:ok, %State{state | image: image, materialized?: true, pending_orientation: nil}}
    end
  end

  defp materialize(%State{} = state) do
    case Vix.Vips.Image.copy_memory(state.image) do
      {:ok, image} -> {:ok, %State{state | image: image, materialized?: true}}
      {:error, _} = error -> error
    end
  end

  defp apply_orientation(image, %PendingOrientation{} = po) do
    with {:ok, image} <- maybe_autorotate(image, po),
         {:ok, image} <- maybe_rotate(image, po.user_angle),
         {:ok, image} <- maybe_flip(image, :horizontal, po.user_flip_x),
         {:ok, image} <- maybe_flip(image, :vertical, po.user_flip_y) do
      {:ok, image}
    end
  end

  defp maybe_autorotate(image, %PendingOrientation{auto_rotate?: true}) do
    case Image.autorotate(image) do
      {:ok, {image, _flags}} -> {:ok, image}
      {:error, _} = error -> error
    end
  end

  defp maybe_autorotate(image, %PendingOrientation{auto_rotate?: false}), do: {:ok, image}

  defp maybe_rotate(image, 0), do: {:ok, image}
  defp maybe_rotate(image, angle), do: Image.rotate(image, angle)

  defp maybe_flip(image, _axis, false), do: {:ok, image}
  defp maybe_flip(image, axis, true), do: Image.flip(image, axis)
end
```

- [ ] **Step 4: Run; expect PASS**

Run: `mise exec -- mix test test/image_pipe/transform/orientation_flush_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/orientation_flush.ex test/image_pipe/transform/orientation_flush_test.exs
git commit -m "feat(transform): add OrientationFlush replay primitive (#146)"
```

## Task 3: Add `pending_orientation` to `State`; make `Materializer` flush-aware

State change is inert (default nil). Making `materialize/1` flush-aware is also inert until something sets pending (T9), but routes all three flush entry points through `OrientationFlush`.

**Files:**
- Modify: `lib/image_pipe/transform/state.ex:27-43`
- Modify: `lib/image_pipe/transform/materializer.ex:21-27`
- Test: `test/image_pipe/transform/materializer_test.exs` (the file already exists — extend it; do not recreate)

- [ ] **Step 1: Add the field to State**

In `lib/image_pipe/transform/state.ex`, add `pending_orientation: nil` to `defstruct` (after `source_dimensions:`) and `pending_orientation: ImagePipe.Transform.PendingOrientation.t() | nil` to `@type t`:

```elixir
  defstruct image: nil,
            debug: false,
            detector: nil,
            detector_required: false,
            telemetry_opts: [],
            source_dimensions: nil,
            pending_orientation: nil,
            materialized?: false

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t() | nil,
          debug: boolean(),
          detector: module() | {module(), keyword()} | nil,
          detector_required: boolean(),
          telemetry_opts: keyword(),
          source_dimensions: {pos_integer(), pos_integer()} | nil,
          pending_orientation: ImagePipe.Transform.PendingOrientation.t() | nil,
          materialized?: boolean()
        }
```

- [ ] **Step 2: Write the failing Materializer test**

```elixir
# test/image_pipe/transform/materializer_test.exs
defmodule ImagePipe.Transform.MaterializerTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.{Materializer, PendingOrientation, State}

  test "no pending: copy_memory only, sets materialized?, leaves pending nil" do
    state = %State{image: Image.new!(10, 10, color: :red), materialized?: false}
    assert {:ok, %State{materialized?: true, pending_orientation: nil}} = Materializer.materialize(state)
  end

  test "pending set: applies orientation, materializes, clears pending" do
    base = Image.set_orientation!(Image.new!(40, 20, color: :red), 6)
    po = PendingOrientation.from_exif(6, true)
    state = %State{image: base, pending_orientation: po, materialized?: false}

    assert {:ok, %State{} = result} = Materializer.materialize(state)
    assert result.materialized? == true
    assert result.pending_orientation == nil
    # orientation 6 = 90°: 40x20 storage becomes 20x40 display
    assert {Image.width(result.image), Image.height(result.image)} == {20, 40}
  end
end
```

- [ ] **Step 3: Run; expect failure (pending not applied)**

Run: `mise exec -- mix test test/image_pipe/transform/materializer_test.exs`
Expected: FAIL — the second test sees `{40, 20}` (pending ignored).

- [ ] **Step 4: Make `materialize/1` flush-aware**

In `lib/image_pipe/transform/materializer.ex`, replace `materialize/1` (lines 21-27) so it delegates to `OrientationFlush.flush/1`, which handles both the pending and no-pending cases:

```elixir
  alias ImagePipe.Transform.OrientationFlush

  @spec materialize(State.t()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{} = state) do
    OrientationFlush.flush(state)
  end
```

Keep `materialize/2` (delegates to `/1`) and the `@callback` unchanged. (Add the `alias` near the top alongside the existing `alias ImagePipe.Transform.State`.)

- [ ] **Step 5: Run the new test + existing materialize callers; expect PASS**

Run: `mise exec -- mix test test/image_pipe/transform/materializer_test.exs test/image_pipe/transform/auto_orient_materialize_test.exs test/transform_chain_test.exs`
Expected: PASS (nothing sets pending yet, so the eager paths are unchanged).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/transform/state.ex lib/image_pipe/transform/materializer.ex test/image_pipe/transform/materializer_test.exs
git commit -m "feat(transform): pending_orientation on State; flush-aware Materializer (#146)"
```

## Task 4: `Transform.Orientation` — coordinate compensation (pure)

The single home for orientation x/y transposition: gravity-spec `RotateAndFlip` port, crop dim swap, and resize requested-dim swap. Pure; called only by `PlanExecutor` (T9). Port the gravity remap **verbatim** per spec §3.6.

**Files:**
- Create: `lib/image_pipe/transform/orientation.ex`
- Test: `test/image_pipe/transform/orientation_test.exs`

- [ ] **Step 1: Write the failing compensation table test**

```elixir
# test/image_pipe/transform/orientation_test.exs
defmodule ImagePipe.Transform.OrientationTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Orientation, as: O

  describe "compensate_gravity/4 — directional remap (offsets 0)" do
    # Spec §3.6 directional rotation map (storage = compensate(display)).
    test "anchor types remap under 90/180/270" do
      assert O.compensate_gravity({:anchor, :center, :top}, 90, false, false) ==
               {:anchor, :left, :center}

      assert O.compensate_gravity({:anchor, :center, :top}, 180, false, false) ==
               {:anchor, :center, :bottom}

      assert O.compensate_gravity({:anchor, :center, :top}, 270, false, false) ==
               {:anchor, :right, :center}
    end

    test "corner antipode at 180" do
      assert O.compensate_gravity({:anchor, :left, :top}, 180, false, false) ==
               {:anchor, :right, :bottom}
    end

    test "flipX swaps left/right; flipY swaps top/bottom" do
      assert O.compensate_gravity({:anchor, :left, :top}, 0, true, false) ==
               {:anchor, :right, :top}

      assert O.compensate_gravity({:anchor, :left, :top}, 0, false, true) ==
               {:anchor, :left, :bottom}
    end
  end

  describe "compensate_gravity/4 — focus point" do
    test "90° maps (x,y) -> (y, 1-x)" do
      assert O.compensate_gravity({:fp, 0.25, 0.10}, 90, false, false) == {:fp, 0.10, 0.75}
    end

    test "flipX maps x -> 1-x" do
      assert O.compensate_gravity({:fp, 0.25, 0.10}, 0, true, false) == {:fp, 0.75, 0.10}
    end
  end

  describe "compensate_gravity/4 — never-remapped types" do
    test "smart/detect pass through unchanged (only offsets would change)" do
      assert O.compensate_gravity(:smart, 90, false, false) == :smart
      assert O.compensate_gravity({:smart, :face_assist}, 90, false, false) == {:smart, :face_assist}
    end
  end

  describe "swap_dims?/1 and swap_resize/1" do
    test "swap on quarter-turn only" do
      assert O.swap_dims?(90) and O.swap_dims?(270)
      refute O.swap_dims?(0) or O.swap_dims?(180)
    end

    test "swap_resize swaps width/height, min, zoom; leaves dpr" do
      resize = %ImagePipe.Transform.Operation.Resize{
        width: {:pixels, 100}, height: :auto,
        min_width: {:pixels, 10}, min_height: nil,
        zoom_x: 2.0, zoom_y: 1.0, dpr: 3.0
      }

      swapped = O.swap_resize(resize)
      assert swapped.width == :auto and swapped.height == {:pixels, 100}
      assert swapped.min_width == nil and swapped.min_height == {:pixels, 10}
      assert swapped.zoom_x == 1.0 and swapped.zoom_y == 2.0
      assert swapped.dpr == 3.0
    end
  end
end
```

- [ ] **Step 2: Run; expect failure**

Run: `mise exec -- mix test test/image_pipe/transform/orientation_test.exs`
Expected: FAIL — `Transform.Orientation` undefined.

- [ ] **Step 3: Implement the verbatim `RotateAndFlip` port + swaps**

```elixir
# lib/image_pipe/transform/orientation.ex
defmodule ImagePipe.Transform.Orientation do
  @moduledoc false
  # Orientation coordinate transposition for PRE-FLUSH ops only (gravity crop +
  # resize). Verbatim port of imgproxy gravity.go RotateAndFlip (flipX -> flipY ->
  # rotate; remap type then transform offset on the POST-REMAP type). See spec
  # §3.6 and local/imgproxy-master/processing/gravity.go:8-156.

  alias ImagePipe.Transform.{Operation.Resize, PendingOrientation}

  @type gravity ::
          {:anchor, :left | :center | :right, :top | :center | :bottom}
          | {:fp, float(), float()}
          | :smart
          | {:smart, :face_assist}
          | {:detect, term()}

  @doc "Compensate a gravity spec back to storage frame: user-then-EXIF (spec §3.6)."
  @spec compensate_gravity_for(gravity(), PendingOrientation.t()) :: gravity()
  def compensate_gravity_for(gravity, %PendingOrientation{} = po) do
    gravity
    |> compensate_gravity(po.user_angle, po.user_flip_x, po.user_flip_y)
    |> compensate_gravity(po.exif_angle, po.exif_flip_x, false)
  end

  @doc "Single RotateAndFlip step: flipX -> flipY -> rotate."
  @spec compensate_gravity(gravity(), 0 | 90 | 180 | 270, boolean(), boolean()) :: gravity()
  def compensate_gravity(gravity, angle, flip_x, flip_y) do
    gravity
    |> apply_flip_x(flip_x)
    |> apply_flip_y(flip_y)
    |> apply_rotate(angle)
  end

  @spec swap_dims?(0 | 90 | 180 | 270) :: boolean()
  def swap_dims?(angle), do: rem(angle, 180) == 90

  @doc "Swap a resize op's requested dims/min/zoom for a quarter-turn (spec §3.6)."
  @spec swap_resize(Resize.t()) :: Resize.t()
  def swap_resize(%Resize{} = r) do
    %Resize{
      r
      | width: r.height,
        height: r.width,
        min_width: r.min_height,
        min_height: r.min_width,
        zoom_x: r.zoom_y,
        zoom_y: r.zoom_x
    }
  end

  # ---- flipX (gravity.go:41-48) ----
  defp apply_flip_x(g, false), do: g
  defp apply_flip_x({:anchor, x, y}, true), do: {:anchor, flip_h(x), y}
  defp apply_flip_x({:fp, x, y}, true), do: {:fp, 1.0 - x, y}
  defp apply_flip_x(other, true), do: other

  defp flip_h(:left), do: :right
  defp flip_h(:right), do: :left
  defp flip_h(other), do: other

  # ---- flipY (gravity.go:50-57) ----
  defp apply_flip_y(g, false), do: g
  defp apply_flip_y({:anchor, x, y}, true), do: {:anchor, x, flip_v(y)}
  defp apply_flip_y({:fp, x, y}, true), do: {:fp, x, 1.0 - y}
  defp apply_flip_y(other, true), do: other

  defp flip_v(:top), do: :bottom
  defp flip_v(:bottom), do: :top
  defp flip_v(other), do: other

  # ---- rotate (gravity.go:8-38, 96-152) ----
  defp apply_rotate(g, 0), do: g

  defp apply_rotate({:anchor, x, y}, angle), do: rotate_anchor({:anchor, x, y}, angle)
  defp apply_rotate({:fp, x, y}, 90), do: {:fp, y, 1.0 - x}
  defp apply_rotate({:fp, x, y}, 180), do: {:fp, 1.0 - x, 1.0 - y}
  defp apply_rotate({:fp, x, y}, 270), do: {:fp, 1.0 - y, x}
  defp apply_rotate(other, _angle), do: other

  # Directional rotation map (spec §3.6 table) as compass (h, v) pairs.
  # N=(center,top) S=(center,bottom) E=(right,center) W=(left,center)
  # plus corners. Verbatim bijection.
  for {{h, v}, m90, m180, m270} <- [
        {{:center, :top}, {:left, :center}, {:center, :bottom}, {:right, :center}},
        {{:right, :center}, {:center, :top}, {:left, :center}, {:center, :bottom}},
        {{:center, :bottom}, {:right, :center}, {:center, :top}, {:left, :center}},
        {{:left, :center}, {:center, :bottom}, {:right, :center}, {:center, :top}},
        {{:left, :top}, {:left, :bottom}, {:right, :bottom}, {:right, :top}},
        {{:right, :top}, {:left, :top}, {:left, :bottom}, {:right, :bottom}},
        {{:left, :bottom}, {:right, :bottom}, {:right, :top}, {:left, :top}},
        {{:right, :bottom}, {:right, :top}, {:left, :top}, {:left, :bottom}}
      ] do
    defp rotate_anchor({:anchor, unquote(h), unquote(v)}, 90),
      do: {:anchor, unquote(elem(m90, 0)), unquote(elem(m90, 1))}

    defp rotate_anchor({:anchor, unquote(h), unquote(v)}, 180),
      do: {:anchor, unquote(elem(m180, 0)), unquote(elem(m180, 1))}

    defp rotate_anchor({:anchor, unquote(h), unquote(v)}, 270),
      do: {:anchor, unquote(elem(m270, 0)), unquote(elem(m270, 1))}
  end

  # center stays center under rotation
  defp rotate_anchor({:anchor, :center, :center}, _angle), do: {:anchor, :center, :center}
end
```

> Note: this step compensates gravity **type** (the directional remap). Offset transforms on `x_offset`/`y_offset` (spec §3.6 offset rules) are applied alongside the type remap when PlanExecutor passes the offsets through — extend `compensate_gravity/4` to also return adjusted offsets in T9 if a test there shows offset cases failing. The mapping above is the type bijection the table test pins; verify the corner/center rows against `gravity.go`.

- [ ] **Step 4: Run; expect PASS**

Run: `mise exec -- mix test test/image_pipe/transform/orientation_test.exs`
Expected: PASS. If a row mismatches, fix it against `local/imgproxy-master/processing/gravity.go` (do not guess).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/orientation.ex test/image_pipe/transform/orientation_test.exs
git commit -m "feat(transform): Orientation compensation port (gravity remap + dim/resize swap) (#146)"
```

## Task 5: Add `Plan.auto_rotate` field

**Files:**
- Modify: `lib/image_pipe/plan.ex:48-86`
- Test: `test/image_pipe/plan_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# add to test/image_pipe/plan_test.exs
test "auto_rotate defaults to false and validate_shape accepts booleans" do
  plan = %ImagePipe.Plan{source: valid_source(), pipelines: [%ImagePipe.Plan.Pipeline{operations: []}], output: %ImagePipe.Plan.Output{mode: :automatic}}
  assert plan.auto_rotate == false
  assert {:ok, _} = ImagePipe.Plan.validate_shape(%{plan | auto_rotate: true})
  assert {:error, {:invalid_auto_rotate, _}} = ImagePipe.Plan.validate_shape(%{plan | auto_rotate: "yes"})
end
```

(Use the file's existing `valid_source()`/helpers; if none, build a `%Source.Path{segments: ["images", "cat.jpg"]}`.)

- [ ] **Step 2: Run; expect failure** — `mise exec -- mix test test/image_pipe/plan_test.exs` → key error / no `auto_rotate`.

- [ ] **Step 3: Add the field + validation**

In `lib/image_pipe/plan.ex`: add `auto_rotate: false` to `defstruct` defaults, `auto_rotate: boolean()` to `@type t`, `{:invalid_auto_rotate, term()}` to `@type shape_error()`, a `:ok <- validate_auto_rotate(plan.auto_rotate)` clause in `validate_shape/1`, and:

```elixir
  defp validate_auto_rotate(value) when is_boolean(value), do: :ok
  defp validate_auto_rotate(value), do: {:error, {:invalid_auto_rotate, value}}
```

- [ ] **Step 4: Run; expect PASS** — `mise exec -- mix test test/image_pipe/plan_test.exs`

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plan.ex test/image_pipe/plan_test.exs
git commit -m "feat(plan): add top-level auto_rotate boolean (#146)"
```

## Task 6: Cache key + ETag carry `auto_rotate`

**Files:**
- Modify: `lib/image_pipe/cache/key.ex:63-79`
- Test: `test/image_pipe/cache/key_test.exs`, `test/image_pipe/request/http_cache_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
# test/image_pipe/cache/key_test.exs
test "auto_rotate participates in the cache key" do
  conn = conn(:get, "/_/plain/images/cat.jpg")
  off = build_key!(conn, plan(auto_rotate: false), source_identity())
  on = build_key!(conn, plan(auto_rotate: true), source_identity())
  assert off.data[:auto_rotate] == false
  assert on.data[:auto_rotate] == true
  refute off.hash == on.hash
end
```

```elixir
# test/image_pipe/request/http_cache_test.exs
test "auto_rotate changes the generated etag (unlike cachebuster)" do
  off = HTTPCache.prepare(conn(:get, "/image"), %{plan() | auto_rotate: false}, resolved(), opts())
  on = HTTPCache.prepare(conn(:get, "/image"), %{plan() | auto_rotate: true}, resolved(), opts())
  refute off.etag == on.etag
end
```

Update the `plan/0` helper in `key_test.exs` to accept `auto_rotate` (it already merges overrides via `struct!`). Add `auto_rotate: false` to the canonical full-key literal assertion (the `key.data == [...]` block) as a top-level entry.

- [ ] **Step 2: Run; expect failure** — `mise exec -- mix test test/image_pipe/cache/key_test.exs test/image_pipe/request/http_cache_test.exs`

- [ ] **Step 3: Emit `auto_rotate` in `plan_material/2`**

In `lib/image_pipe/cache/key.ex`, add `auto_rotate: plan.auto_rotate` to the keyword list returned by `plan_material/2` (a **top-level** entry, NOT under `:cache`):

```elixir
      {:ok,
       [
         pipelines: pipelines,
         transform: transform_data(),
         detector: Keyword.get(opts, :detector_identity),
         output: output,
         auto_rotate: plan.auto_rotate,
         representation: representation_data(),
         cache: cache
       ]}
```

(The ETag picks it up automatically: `etag_material` includes all of `plan_material` minus `:cache`.)

- [ ] **Step 4: Run; expect PASS** — same command. Fix the full-key literal in `key_test.exs` if it still mismatches (add `auto_rotate: false` in canonical order).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/key.ex test/image_pipe/cache/key_test.exs test/image_pipe/request/http_cache_test.exs
git commit -m "feat(cache): auto_rotate participates in key and etag (#146)"
```

## Task 7: Parser surfaces a single `auto_rotate` boolean (op still emitted)

This sets `Plan.auto_rotate` while STILL emitting the AutoOrient op — an inert, green intermediate (the op does orientation; the boolean is redundant metadata until T9).

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/parsed_request.ex:18-25,44-53`
- Modify: `lib/image_pipe/parser/imgproxy/options.ex:30-43,295-315`
- Modify: `lib/image_pipe/parser/imgproxy.ex:216-235`
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex:23-44`
- Test: `test/parser/imgproxy_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# add to test/parser/imgproxy_test.exs
test "Plan.auto_rotate reflects ar option / default" do
  assert {:ok, %ImagePipe.Plan{auto_rotate: true}} =
           Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg"), imgproxy: [auto_rotate: true])

  assert {:ok, %ImagePipe.Plan{auto_rotate: false}} =
           Imgproxy.parse(conn(:get, "/_/ar:false/plain/images/cat.jpg"), imgproxy: [auto_rotate: true])

  assert {:ok, %ImagePipe.Plan{auto_rotate: true}} =
           Imgproxy.parse(conn(:get, "/_/ar:true/plain/images/cat.jpg"), imgproxy: [auto_rotate: false])
end
```

- [ ] **Step 2: Run; expect failure** — `mise exec -- mix test test/parser/imgproxy_test.exs:<line>`

- [ ] **Step 3: Thread the boolean**

1. `parsed_request.ex`: add `auto_rotate: false` to `defstruct` defaults + `auto_rotate: boolean()` to `@type t`.
2. `options.ex` `apply_request_defaults/2`: it already computes `auto_rotate? = effective_auto_rotate(...)`. Return it on the map: change the final `%{options | pipelines: pipelines, output: output}` to also set `auto_rotate: auto_rotate?`. Add `:auto_rotate` to the `Map.take/2` list in `parse/3` (line 39) and `auto_rotate: boolean()` to `@type request_options`.
3. `imgproxy.ex` `parsed_request/4`: add `auto_rotate: request_options.auto_rotate` to the `%ParsedRequest{}`.
4. `plan_builder.ex` `to_plan/2`: add `auto_rotate: request.auto_rotate` to the `%Plan{}`.

> Leave `apply_auto_rotate_to_first_pipeline/2` and `auto_orient_operation/1` in place for now (op still emitted). T9 removes them.

- [ ] **Step 4: Run; expect PASS** — `mise exec -- mix test test/parser/imgproxy_test.exs`

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/parsed_request.ex lib/image_pipe/parser/imgproxy/options.ex lib/image_pipe/parser/imgproxy.ex lib/image_pipe/parser/imgproxy/plan_builder.ex test/parser/imgproxy_test.exs
git commit -m "feat(parser): surface Plan.auto_rotate boolean (op still emitted) (#146)"
```

## Task 8: `decode_planner` uses `auto_rotate` instead of scanning for `%AutoOrient{}`

**Files:**
- Modify: `lib/image_pipe/transform/decode_planner.ex:16-64`
- Modify: `lib/image_pipe/request/processor.ex:71-77`
- Test: `test/image_pipe/decode_planner_test.exs`

- [ ] **Step 1: Rewrite the swap test to the boolean form**

Replace the `decode_planner_test.exs` test "EXIF quarter-turn swaps the shrink axes only when the chain auto-orients" with:

```elixir
test "EXIF quarter-turn swaps shrink axes only when auto_rotate AND exif_quarter_turn?" do
  assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, :auto)
  chain = [resize]

  # auto_rotate true + quarter-turn => swap => shrink on 800 width
  swapped = DecodePlanner.open_options(chain, :jpeg, {3200, 800}, true, true)
  assert swapped[:shrink] == 2

  # auto_rotate false + quarter-turn => no swap => shrink on 3200
  no_ar = DecodePlanner.open_options(chain, :jpeg, {3200, 800}, true, false)
  assert no_ar[:shrink] == 8

  # auto_rotate true + not quarter-turn => no swap
  not_qt = DecodePlanner.open_options(chain, :jpeg, {3200, 800}, false, true)
  assert not_qt[:shrink] == 8
end
```

- [ ] **Step 2: Run; expect failure** — `mise exec -- mix test test/image_pipe/decode_planner_test.exs`

- [ ] **Step 3: Change `open_options/4 → /5` and drop the chain scan**

In `decode_planner.ex`: remove the `alias ImagePipe.Plan.Operation.AutoOrient` and `auto_orient_before_resize?/1`. Change the signature to add `auto_rotate?` and gate the swap on `auto_rotate? and exif_quarter_turn?`:

```elixir
  def open_options(chain, source_format, {src_w, src_h}, exif_quarter_turn? \\ false, auto_rotate? \\ false)
      when is_list(chain) and is_atom(source_format) and is_integer(src_w) and src_w > 0 and
             is_integer(src_h) and src_h > 0 and is_boolean(exif_quarter_turn?) and
             is_boolean(auto_rotate?) do
    {shrink_w, shrink_h} = shrink_axes({src_w, src_h}, auto_rotate? and exif_quarter_turn?)
    base = [access: :sequential, fail_on: :error]
    load_shrink = compute_load_shrink(chain, shrink_w, shrink_h)
    append_load_option(base, source_format, load_shrink)
  end

  defp shrink_axes({w, h}, true), do: {h, w}
  defp shrink_axes(dims, false), do: dims
```

In `processor.ex` (the `open_options(...)` call ~line 71-77), pass both booleans:

```elixir
       decode_options =
         DecodePlanner.open_options(
           operations,
           source_format,
           original_dims,
           exif_quarter_turn?(header_image),
           plan.auto_rotate
         ),
```

(`plan` is in scope in `decode_validate_source_response/3`.)

- [ ] **Step 4: Run; expect PASS** — `mise exec -- mix test test/image_pipe/decode_planner_test.exs`

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/decode_planner.ex lib/image_pipe/request/processor.ex test/image_pipe/decode_planner_test.exs
git commit -m "feat(decode): swap shrink axes from auto_rotate boolean, not AutoOrient scan (#146)"
```

## Task 9: CUTOVER — PlanExecutor seeds pending, compensates, flushes; stop emitting the op

This is the behavior-preserving cutover. **Split into T9a (seed + flush, no compensation needed) and T9b (compensation), each committed green.** Crucially, the parser de-emission and the tests that assert the AutoOrient *plan op is emitted/executed* move **into this task** (T9a), so each commit stays green — T10 becomes module-deletion-only.

> **Gate oracle — do NOT use `Image.thumbnail!` as the reference.** The pipeline resizes with `Image.resize` (affine), not `Image.thumbnail` (different kernel + shrink-on-load + crop); comparing them is flaky and wrong. Two sound oracles:
> 1. **Orientation-only leg** (no crop/resize): reference = `autorotate ∘ Image.rotate ∘ Image.flip` applied to the source — same primitives the flush uses.
> 2. **Commutation leg** (crop/resize present): the **request-boundary wire pixel test** is the primary gate — run the request on the EXIF-oriented source AND on a **pre-oriented orientation-1 source** carrying the same displayed pixels, and assert the decoded outputs match pixel-for-pixel. Identical operators on both sides ⇒ rounding cancels ⇒ byte-identity is actually provable. (See T11 Step 1.)

### T9a — seed + per-pipeline flush + stop emitting the op

**Files:**
- Modify: `lib/image_pipe/transform/plan_executor.ex` (seed, fold rotate/flip, per-pipeline flush; drop `PlanAutoOrient`/`PlanRotate`/`PlanFlip` executable clauses)
- Modify: `lib/image_pipe/request/processor.ex` (pass `seed_orientation: index == 0`)
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex:275-285` (drop `auto_orient_operation`)
- Modify: `lib/image_pipe/parser/imgproxy/options.ex` (remove `apply_auto_rotate_to_first_pipeline` re-stamp)
- Modify (same commit, to stay green): `test/parser/imgproxy_test.exs`, `test/parser/imgproxy/plan_builder_test.exs`, `test/image_pipe/transform/plan_executor_test.exs` (`:290` feeds a `%AutoOrient{}` plan op through `execute_plan` → drop it) — every test that asserts the AutoOrient **plan op is emitted/executed**.
- Test: new `test/image_pipe/transform/deferred_orientation_test.exs` (orientation-only + no-geometry legs)

- [ ] **Step 1: Write the failing orientation-only gate test (same-primitive reference)**

```elixir
# test/image_pipe/transform/deferred_orientation_test.exs
defmodule ImagePipe.Transform.DeferredOrientationTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.{PlanExecutor, Materializer, State}
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.{Rotate, Flip}

  defp marked(w, h), do: Image.Draw.rect!(Image.new!(w, h, color: :white), 0, 0, 4, 4, color: :red)

  defp run(plan, image) do
    {:ok, %State{} = s} = PlanExecutor.execute(plan, %State{image: image}, seed_orientation: true)
    {:ok, %State{} = s} = Materializer.materialize(s)  # delivery backstop flush
    s.image
  end

  # Orientation-only reference uses the SAME primitives the flush uses.
  defp orientation_only_reference(image, user_rotate, user_flips) do
    {:ok, {img, _}} = Image.autorotate(image)
    img = if user_rotate != 0, do: Image.rotate!(img, user_rotate), else: img
    Enum.reduce(user_flips, img, fn axis, acc -> Image.flip!(acc, axis) end)
  end

  defp sample_positions(size), do: (l = max(size - 1, 0)) && Enum.uniq([0, div(l, 2), l])

  defp assert_pixels_match(a, b) do
    assert {Image.width(a), Image.height(a)} == {Image.width(b), Image.height(b)}
    for x <- sample_positions(Image.width(a)), y <- sample_positions(Image.height(a)) do
      assert Image.get_pixel!(a, x, y) == Image.get_pixel!(b, x, y), "mismatch at (#{x},#{y})"
    end
  end

  defp plan(ops, auto_rotate?), do:
    %Plan{source: nil, output: nil, auto_rotate: auto_rotate?,
          pipelines: [%ImagePipe.Plan.Pipeline{operations: ops}]}

  test "no-geometry EXIF 1..8 + user rotate/flip: deferred flush matches same-primitive reference" do
    for orientation <- 1..8, user_rotate <- [0, 90, 180, 270], flips <- [[], [:horizontal], [:vertical]] do
      base = Image.set_orientation!(marked(40, 20), orientation)
      ops = Enum.reject([(user_rotate != 0 && elem(Operation.rotate(user_rotate), 1)) || nil] ++
                        Enum.map(flips, &(elem(Operation.flip(&1), 1))), &is_nil/1)
      out = run(plan(ops, true), base)
      assert_pixels_match(out, orientation_only_reference(base, user_rotate, flips))
    end
  end
end
```

> Build the `Plan` pipeline ops via the real constructors `Operation.rotate/1`, `Operation.flip/1` (which return `{:ok, struct}`), and for crop/resize in T9b use `Operation.resize/4` / `Operation.crop_guided/...` — never hand-build `%Plan.Operation.Resize{}` literally (it `@enforce_keys [:mode,:width,:height,:dpr,:enlargement,:guide]` and a partial literal raises a compile/`ArgumentError`).

- [ ] **Step 2: Run; expect failure** — `mise exec -- mix test test/image_pipe/transform/deferred_orientation_test.exs` (PlanExecutor doesn't seed/compensate yet).

- [ ] **Step 3: PlanExecutor — seeding + folding + per-pipeline flush**

In `plan_executor.ex` `execute/3`, read the seed signal and seed `pending_orientation` (first pipeline only). Thread pending through `execute_pipeline` and flush at the boundary:

```elixir
  def execute(%Plan{pipelines: pipelines, auto_rotate: auto_rotate}, %State{} = state, opts) do
    state = %{
      state
      | detector: ImagePipe.Transform.resolve_detector(Keyword.get(opts, :detector, :default)),
        detector_required: Keyword.get(opts, :detector_required, false),
        telemetry_opts: Telemetry.telemetry_opts(opts)
    }

    state =
      if Keyword.get(opts, :seed_orientation, false) do
        %State{state | pending_orientation: PendingOrientation.from_exif(orientation(state.image), auto_rotate)}
      else
        state
      end

    execute_pipelines(pipelines, state, opts)
  end

  defp orientation(image) do
    case Vix.Vips.Image.header_value(image, "orientation") do
      {:ok, v} when is_integer(v) -> v
      _ -> 1
    end
  end
```

At the end of `execute_pipeline/3`, after the operations reduce, flush any still-pending orientation (per-pipeline boundary):

```elixir
    |> case do
      {:ok, state, _context} -> flush_if_pending(state)
      {:error, _reason} = error -> error
    end
  end

  defp flush_if_pending(%State{pending_orientation: nil} = state), do: {:ok, state}
  defp flush_if_pending(%State{} = state), do: ImagePipe.Transform.Materializer.materialize(state)
```

(Add `alias ImagePipe.Transform.PendingOrientation` to the alias block.)

> `processor.ex` must pass `seed_orientation: index == 0` per pipeline. In `execute_plan_pipeline_step/4`, the tuple already carries the index — change it to pass `Keyword.put(opts, :seed_orientation, index == 0)` into `Transform.execute_plan`.

- [ ] **Step 4: PlanExecutor — fold user Rotate/Flip into pending instead of emitting ops**

Replace the `executable_operations` clauses for `%PlanRotate{}` and `%PlanFlip{}` so they fold into pending and emit no executable op. Because folding mutates `State`, do it in `execute_operation/4` (which has the state) rather than `executable_operations/3`. Add ahead of the generic `execute_operation`:

```elixir
  defp execute_operation(%PlanRotate{angle: angle}, %State{pending_orientation: %PendingOrientation{} = po} = state, _ctx, _opts) do
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_rotate(po, angle)}}
  end

  defp execute_operation(%PlanFlip{axis: axis}, %State{pending_orientation: %PendingOrientation{} = po} = state, _ctx, _opts) do
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_flip(po, axis)}}
  end
```

Remove the `executable_operations(%PlanAutoOrient{}, ...)` clause (the plan op is gone after this task) and the `%PlanRotate{}`/`%PlanFlip{}` executable clauses (now handled above). Keep the executable `Rotate`/`Flip` modules — `OrientationFlush` doesn't use them, but other code/tests may.

> Edge: if `pending_orientation` is nil (e.g. a second pipeline with a user rotate, no EXIF), seed an empty `%PendingOrientation{}` on first fold so the flush still fires. Add a fallback clause matching `pending_orientation: nil` that seeds `%PendingOrientation{}` then folds.

### T9b — compensation (gravity remap + offsets + dim/resize swap + flush placement)

Commit this separately from T9a; gate it on the crop/resize matrix (T11 Step 1, wire-vs-orientation-1 oracle) + `test/image_pipe/shrink_on_load_test.exs` (the residual-resize/`source_dimensions` test the cutover most threatens — add it to this task's gate).

- [ ] **Step 5: PlanExecutor — compensate pre-flush crop + resize; force flush after resize / before region crop**

Compensation operates on the **executable** tagged gravity (the `%Crop{}.gravity` field that `executable_operations(%CropGuided{}, ...)` builds via `tagged_executable_gravity/1` — shapes `{:anchor,h,v}` / `{:fp,x,y}` / `:smart` / `{:detect,_}`), **not** the plan-level `%CropGuided{}.guide` (`{:focal, {:ratio..}, {:ratio..}}`). In `execute_operation/4`, when `pending_orientation` is live and non-identity:

- **Gravity crop (`%CropGuided{}`)**: build the `%Crop{}` as today, then compensate its `gravity` **type AND `x_offset`/`y_offset`** via `Orientation.compensate_gravity_for/2`, and swap the `%Crop{}` width/height when `quarter_turn?`. **Offset compensation is required, not optional** — imgproxy's `RotateAndFlip` transforms offsets too (`gravity.go:96-153`: e.g. 90° center/E/W → `X,Y = Y,-X`; FP → `Y,1-X`; flipX → `-X`/`1-x`). `CropGuided` carries non-zero `x_offset`/`y_offset` (real reachable input), so without this an oriented source + `g:no:0:20`-style offset crops at the wrong location. `Orientation.compensate_gravity/4` must therefore take and return the offsets; extend the T4 module + its table test to cover offset transforms per angle/flip. Smart/detect guides emit literal (the auto-flush at the materializing crop fires first).
- **Region crop (`%CropRegion{}`)**: force a flush first (`flush_if_pending`), then run the region crop literally on oriented pixels.
- **Resize (`%PlanResize{}`)**: build the executable as today, then `Orientation.swap_resize/1` on each `%Resize{}` when `quarter_turn?`; after running, force a flush so the result crop / tail are post-flush.

Sketch (wrap the existing `executable_operations |> Chain.execute` path):

```elixir
  defp execute_operation(%CropRegion{} = op, %State{pending_orientation: po} = state, ctx, opts) when po != nil do
    with {:ok, state} <- flush_if_pending(state) do
      execute_operation(op, %State{state | pending_orientation: nil}, ctx, opts)
    end
  end

  defp execute_operation(%PlanResize{} = op, %State{pending_orientation: po} = state, ctx, opts) when po != nil do
    executable = op |> executable_operations(state, ctx) |> compensate_resize(po)
    with {:ok, state} <- Chain.execute(state, executable, opts) do
      flush_if_pending(state)   # flush right after the resize stage (spec §3.5 case 3)
    end
  end
```

where `compensate_resize/2` maps `Orientation.swap_resize/1` over the `%Resize{}` ops in the expansion when `PendingOrientation.quarter_turn?(po)`, and gravity crop compensation is applied to the `%Crop{}` built in `executable_operations` for `%CropGuided{}`.

> This is the densest change. Implement it incrementally against the T11 crop/resize matrix (wire-vs-orientation-1 oracle) + `test/image_pipe/imgproxy_wire_conformance_test.exs` + `test/image_pipe/shrink_on_load_test.exs`, running `mise exec -- mix test <those files>` after each sub-change. `compensate_gravity_for/2` transforms both gravity type and offsets (required, per Step 5).

- [ ] **Step 6: Stop emitting the AutoOrient op in the parser**

In `plan_builder.ex` `orientation_operations/1`, drop `auto_orient_operation(orientation)` from the list (keep `rotate_operation`/`flip_operation`). In `options.ex`, delete `apply_auto_rotate_to_first_pipeline/2` and its call in `apply_request_defaults/2` (the boolean is now surfaced directly from T7). `consume_auto_rotate_request/1` stays (it clears the per-pipeline carrier).

- [ ] **Step 7: Wire-conformance — add ar:0 / no-geometry cases, decode-and-sample PIXELS (not just dims)**

The existing test `test/image_pipe/imgproxy_wire_conformance_test.exs:608-637` (autorotate on/off ⇒ `{80,40}`/`{40,80}`) must pass unchanged. Add the cases below. **Dimensions alone can't tell a correct 90° from a wrong-direction one** — sample pixels too (helpers `decoded_image/1`, `sampled_pixels/1` exist). The fixture `oriented.jpg` is **stored 40w×80h, EXIF 6** (autorotate ⇒ 80×40).

```elixir
test "ar:0 + EXIF-6 + user rot:90 applies only the user rotation (regression guard)" do
  conn = call_imgproxy("/_/ar:false/rot:90/f:jpeg/plain/images/oriented.jpg",
           exif_orientation_origin_opts(imgproxy: [auto_rotate: true]))
  assert conn.status == 200
  # ar:0 ignores the EXIF tag; user rot:90 on the STORED 40x80 -> 80x40
  assert dimensions(conn) == {80, 40}
  assert sampled_pixels(decoded_image(conn)) == sampled_pixels(reference_user_rot90_storage())
end

test "no-geometry: rot:90 on EXIF-6 (ar:1) = 180° net" do
  conn = call_imgproxy("/_/rot:90/f:jpeg/plain/images/oriented.jpg",
           exif_orientation_origin_opts(imgproxy: [auto_rotate: true]))
  assert conn.status == 200
  # EXIF-6 (90°) THEN user 90° = 180° net on the stored 40x80 -> stays 40x80 (NOT 80x40)
  assert dimensions(conn) == {40, 80}
  assert sampled_pixels(decoded_image(conn)) == sampled_pixels(reference_180_of_stored())
end
```

`reference_user_rot90_storage/0` builds the fixture's stored 40×80 image (no autorotate) and applies `Image.rotate!(_, 90)`; `reference_180_of_stored/0` applies `Image.rotate!(_, 180)` — same-primitive oracles so direction is pinned, not just the bounding box.

- [ ] **Step 8: Run the T9 gates green**

Run: `mise exec -- mix test test/image_pipe/transform/deferred_orientation_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs test/image_pipe/transform/plan_executor_test.exs test/parser/imgproxy_test.exs test/parser/imgproxy/plan_builder_test.exs`
Expected: PASS. Because the plan-op-emission test fixes are folded into T9a/T9b, **each T9 commit is green** (T10 only deletes modules + tests that *name* the deleted modules).

- [ ] **Step 9: Commit (two commits — T9a then T9b)**

```bash
# after T9a (seed/flush/de-emit + plan-op test fixes):
git add lib/image_pipe/transform/plan_executor.ex lib/image_pipe/request/processor.ex lib/image_pipe/parser/imgproxy/plan_builder.ex lib/image_pipe/parser/imgproxy/options.ex test/image_pipe/transform/deferred_orientation_test.exs test/parser/imgproxy_test.exs test/parser/imgproxy/plan_builder_test.exs test/image_pipe/transform/plan_executor_test.exs
git commit -m "feat(transform): defer orientation — seed pending + per-pipeline flush; stop emitting AutoOrient op (#146)"
# after T9b (compensation):
git add lib/image_pipe/transform/plan_executor.ex lib/image_pipe/transform/orientation.ex test/image_pipe/transform/orientation_test.exs test/image_pipe/transform/deferred_orientation_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "feat(transform): compensate pre-flush crop/resize (gravity+offsets, dim/resize swap) (#146)"
```

## Task 10: Delete the dead AutoOrient modules; fix the tests that NAME the deleted modules

By T9 the plan op is no longer emitted/executed and parser/plan-op-emission tests are already green. T10 is **module deletion only** + rewriting/deleting the tests that reference the now-deleted module names — so this commit is also green.

**Files:**
- Delete: `lib/image_pipe/plan/operation/auto_orient.ex`, `lib/image_pipe/transform/operation/auto_orient.ex`
- Delete: `test/image_pipe/transform/auto_orient_materialize_test.exs` (NOTE: it is at `…/transform/`, **not** `…/transform/operation/`), `test/image_pipe/transform/operation/auto_orient_test.exs`
- Modify (production): `plan.ex:22` (drop export), `plan/operation.ex:7,72,99-100,341`, `plan/key_data.ex:11,126`, `transform.ex:25` (drop export), `transform/plan_executor.ex` (drop `PlanAutoOrient` alias; drop the executable `AutoOrient` alias if now unused), `transform/state.ex:18-24,99` (update the moduledoc — `source_dimensions` is no longer swapped by AutoOrient; it stays storage-frame).
- Modify (tests that NAME the deleted modules): `test/image_pipe/architecture_boundary_test.exs` (`@concrete_plan_names` line ~59 **and** `@concrete_transform_names` line ~80; plan export-include list ~476 **and** transform export-include list ~442), `test/transform_chain_test.exs:288-289` (drives the executable `AutoOrient` op + asserts `:auto_orient` telemetry — delete that case, its behavior is gone), `test/image_pipe/transform/prefetch_validation_test.exs:37`, `test/image_pipe/transform/sequential_access_test.exs:152-157` (see Step 3), `test/image_pipe/plan_test.exs:120`, `test/image_pipe/plan/operation_test.exs:375,381,397`, `test/image_pipe/plan/operation_key_data_test.exs:209`, `test/parser/imgproxy/options_test.exs:26`, `test/image_pipe/shrink_on_load_test.exs` (if it names the op struct), `test/image_pipe/decode_planner_test.exs` (any residual `%AutoOrient{}` alias/chain). The grep sweep in Step 4 is authoritative.

- [ ] **Step 1: Remove production references + delete the two `auto_orient.ex` files** (mechanical, per spec §3.2 call-site inventory). Use `grep -rn "AutoOrient" lib` to confirm zero `lib/` references remain. Update the `State` moduledoc (`state.ex:18-24,99`) so it no longer claims AutoOrient swaps `source_dimensions`.

- [ ] **Step 2: Fix the architecture boundary test (4 sites, all exact-equality assertions):**
  - drop `:AutoOrient` from `@concrete_plan_names` (~line 59),
  - drop `:AutoOrient` from `@concrete_transform_names` (~line 80),
  - drop `ImagePipe.Plan.Operation.AutoOrient` from the plan export-include assertion (~line 476),
  - drop `ImagePipe.Transform.Operation.AutoOrient` from the transform export-include assertion (~line 442).
  These are `==` assertions — a stale entry is a hard failure.

- [ ] **Step 3: Preserve the mandated sequential-safety gate.** `sequential_access_test.exs:152-157` is the CLAUDE.md-mandated streamed-source (`access: :sequential, fail_on: :error`) sequential-vs-random gate for orientation, with the transpose self-check. Deleting it loses a required gate. Move its streamed-open + transpose-self-check coverage into `orientation_flush_test.exs` (T2) or `deferred_orientation_test.exs` so the streamed gate survives the AutoOrient removal. Also add a **positive `source_dimensions` test**: under a pending quarter-turn, the residual `source_dimensions` stays in the **storage frame** (replacing the deleted `auto_orient_test.exs` swap coverage; spec §3.6 / §10).

- [ ] **Step 4: Full suite + grep sweep + compile/credo**

Run: `mise exec -- mix test` then `grep -rn "AutoOrient" lib test` (expect zero in `lib/`; only the new `orientation_*` files in `test/`).
Then: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix credo --strict`
Expected: green; no warnings; no credo issues.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: delete AutoOrient modules; preserve sequential gate + source_dimensions test (#146)"
```

## Task 11: Slice A gate tests — matrix, detector ordering, metadata, property

**Files:**
- Modify: `test/image_pipe/transform/deferred_orientation_test.exs`
- Modify: `test/support/fake_detector.ex`
- Test: detector-ordering, strip-metadata tag, property test (in the wire test file or a new property test file)

- [ ] **Step 1: Crop/resize matrix — wire-vs-orientation-1 oracle.** For cases WITH crop/resize, the oracle is NOT a synthesized reference: run the same logical request twice — once on the EXIF-oriented source, once on a **pre-oriented orientation-1 source** carrying the same displayed pixels — and assert the decoded outputs match pixel-for-pixel (identical operators ⇒ rounding cancels). Cover EXIF 1–8 (incl. mirrors 2/4/5/7) × {anchor crop, **anchor crop with non-zero `g:…:x:y` offset**, focus-point crop, **focus-point with offset**, smart crop, region crop, cover/`auto` result crop} × user rotate/flip. Include rounding-sensitive (coprime/odd) source dims for **fit/fill/force × {EXIF 6, EXIF 8}**, and at least one **fill + min-dimension (`mw`/`mh`) + quarter-turn** and **force + quarter-turn** case (where the requested-dim swap most easily diverges). Run: `mise exec -- mix test test/image_pipe/transform/deferred_orientation_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs`.

- [ ] **Step 2: Detector-ordering gate** — add `record_to: pid` to `FakeDetector.detect/2`:

```elixir
  @impl true
  def detect(image, opts) do
    case Keyword.get(opts, :record_to) do
      nil -> :ok
      pid -> send(pid, {:detect_dims, Image.width(image), Image.height(image)})
    end
    Keyword.get(opts, :result, {:ok, []})
  end
```

Then a test that **asserts concrete oriented dims** (an unbound `{:detect_dims, w, h}` would pass even on un-flushed storage dims). Use a guide that actually reaches `run_detect` — `{:detect, …}` or `{:smart, :face_assist}` with a detector present, NOT bare `:smart` (which falls back to attention saliency and never calls `detect/2`). For the orientation-6 origin (stored 40×80, displays 80×40), with `detector: {FakeDetector, record_to: self()}`:

```elixir
assert_receive {:detect_dims, 80, 40}   # display frame — flush preceded detection
```

Add the **negative control**: the same source with `auto_rotate: false` must report storage dims (`{:detect_dims, 40, 80}`), proving the assertion is sensitive to the flush. Keep a `@tag :image_vision` real-detector smoke test.

- [ ] **Step 3: Embedded-orientation-tag assertions** — with `st:0` (`strip_metadata: false`): (a) `ar:1`+tag → output tag absent + rotated; (b) `ar:0`+tag → tag present + unrotated; (c) `ar:1`+orientation 1 → unchanged. Read the output tag via `Image.open!(conn.resp_body) |> then(&Vix.Vips.Image.header_value(&1, "orientation"))`. **Caveat:** (b) holds only because `st:0` disables stripping — do NOT generalize to "ar:0 preserves the tag"; under default `st:1`, imgproxy (`strip_metadata.go`) strips the orientation tag regardless of `auto_rotate`, so assert that case under `st:0` only.

- [ ] **Step 4: Property test** — EXIF 1–8 × random rotate/flip × random crop+resize: decoded output within ±1px of and matching the libvips reference. Model on `test/image_pipe/shrink_on_load_property_test.exs`.

- [ ] **Step 5: Full gate + commit**

Run: `mise run precommit`
Expected: PASS.

```bash
git add -A
git commit -m "test: deferred-orientation gates — matrix, detector ordering, metadata, property (#146)"
```

---

# SLICE B — Shrink-on-load through a preceding crop (#151)

> Gated behind Slice A green. Pure perf; output stays equivalent. Do NOT start until `mise run precommit` is green on Slice A.

## Task B1: Allow shrink-on-load through a preceding gravity crop (rescale crop coords)

**Files:**
- Modify: `lib/image_pipe/transform/decode_planner.ex` (`shrink_blocked_before_resize?/1`, add crop-coordinate rescale)
- Test: `test/image_pipe/decode_planner_test.exs`, `test/image_pipe/shrink_on_load_property_test.exs`

- [ ] **Step 1: Failing test** — assert `open_options` now returns a shrink for a `[%CropGuided{}, %PlanResize{}]` chain (today it returns no shrink because `shrink_blocked_before_resize?` halts on `CropGuided`). Assert the rescaled crop dims/absolute offsets.

- [ ] **Step 2: Run; expect failure.**

- [ ] **Step 3: Implement** — in `shrink_blocked_before_resize?/1` drop the `%CropGuided{}`/`%CropRegion{}` halts (keep min-dimension handling). Rescale crop dims + absolute gravity offsets (`|offset| >= 1`) by the realized preshrink factor; leave focus-point/relative offsets. Mirror `local/imgproxy-master/processing/scale_on_load.go:136-153`.

- [ ] **Step 4: Pixel-equivalence test** — shrink-through-crop vs full-decode+crop within ±1px, absolute AND focus-point gravities (extend `shrink_on_load_property_test.exs`).

- [ ] **Step 5: Decode-limit guardrail test** — an over-limit source with crop+resize that *would* shrink still fails with the pixel-limit error (`validate_original_pixels` keys off un-shrunk header dims).

- [ ] **Step 6: Commit.**

```bash
git add lib/image_pipe/transform/decode_planner.ex test/image_pipe/decode_planner_test.exs test/image_pipe/shrink_on_load_property_test.exs
git commit -m "perf(decode): shrink-on-load through a preceding crop, rescaled coords (#151)"
```

## Task B2: Lift the `Rotate(90|270)` shrink-block via the orientation axis-swap

**Files:**
- Modify: `lib/image_pipe/transform/decode_planner.ex`
- Test: `test/image_pipe/decode_planner_test.exs`, property test

- [ ] **Step 1: Failing test** — `[%Rotate{angle: 90}, %PlanResize{}]` now yields a shrink (swapped axes), with output pixel-equivalent to full-decode.
- [ ] **Step 2: Run; expect failure.**
- [ ] **Step 3: Implement** — drop the `%Rotate{angle: 90|270}` halt; swap the shrink axes for a user quarter-turn (same `swap_axes` mechanism, now also driven by a preceding user `Rotate`). Compose with the EXIF swap from T8.
- [ ] **Step 4: Pixel-equivalence + property test.**
- [ ] **Step 5: Full gate** — `mise run precommit`. Commit.

```bash
git add -A
git commit -m "perf(decode): allow shrink through a preceding 90/270 rotate (#151)"
```

---

## Self-Review

**Spec coverage (v3 sections → tasks):**
- §3.1 pending state → T1, T3. §3.2 EXIF→boolean + call-site inventory → T5, T7, T10. §3.3 two-frame swap → T4 (`swap_dims?`/`swap_resize`), T9. §3.4 PlanExecutor responsibilities → T9. §3.5 flush rule/mechanism → T2, T3, T9 (after-resize + region force-flush + per-pipeline + backstop). §3.6 compensation port → T4, T9. §3.7 output-equivalence → T9, T11 gates. §4 Slice B → B1, B2. §5 decode_planner rework → T8. §6 cache/etag → T6. §7 boundaries → enforced by `architecture_boundary_test` updates in T10. §8 tests → T2/T4/T9/T11 (libvips reference, no-geometry, compensation unit, detector ordering, metadata tag, property) + B1/B2. §9 out-of-scope → respected (no demo change, no FlushOrientation op, no cross-pipeline carry). §10 risks → ar:0 guard (T2/T9), effects timing (backstop in T3/T9).

**Plan-review cycle applied (2026-06-03, 4 disjoint lenses incl. imgproxy-compat).** Accepted fixes folded in: the reference oracle switched from `Image.thumbnail!` (wrong operator) to wire-vs-orientation-1-source pixel comparison (T9/T11); the `rot:90`+EXIF-6 wire assertion corrected to `{40,80}`; wire tests now sample pixels not just dims; T9 split into green T9a/T9b with plan-op test fixes folded in; T10 reduced to deletion + tests naming deleted modules, with the full architecture-boundary inventory (lines 59/80/442/476), correct deleted-test path, preserved sequential-safety gate, and a positive `source_dimensions`-storage-frame test; gravity X/Y **offset** compensation promoted to a required T9b step; plan-level `%Resize{}` built via `Operation.resize/4` (avoids the `@enforce_keys` crash); detector-ordering test asserts concrete oriented dims + a negative control.

**Placeholder scan:** T9b Step 5 remains the densest, judgment-heavy change (compensation + flush insertion across crop/resize) — it carries the exact gate commands + the executable-gravity contract to drive it; subagent-driven execution will review it as its own commit. No fake-complete steps elsewhere.

**Type consistency:** `PendingOrientation` fields used consistently (T1/T2/T9). `Orientation.compensate_gravity/4` (now takes+returns offsets), `compensate_gravity_for/2`, `swap_dims?/1`, `swap_resize/1` match T4↔T9. `OrientationFlush.flush/1` is the single primitive behind `Materializer.materialize/1` (T3) and `flush_if_pending` (T9). `open_options/5` matches T8↔processor.

**Known fragile spots to verify during execution (not blockers):**
- T1 EXIF mapping and T4 anchor/offset tables must be verified against `local/imgproxy-master/processing/{prepare,gravity}.go`, not trusted blindly — both tasks say so (the compat review confirmed the current table is correct, but the offset transforms added in T9b need the same verification).
- The wire-vs-orientation-1 oracle assumes a pre-oriented orientation-1 fixture with the same displayed pixels exists/can be built — construct it from the same source bytes pre-rotated, or assert against `sampled_pixels` of a same-primitive reference where a true twin isn't available.
