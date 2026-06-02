# Per-Op Materialization (Sequential-Access) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the binary load-time access decision (always `:random` if any op needs it) with always-`:sequential` decode plus inline per-op materialization, so most transforms stream and only genuinely random-access ops copy to RAM.

**Architecture:** Each transform op declares `requires_materialization?/1` (a new `ImagePipe.Transform` behaviour callback, default `false`). `Transform.Chain` materializes once, lazily, before the first declaring op via `Materializer.materialize/1`, tracked by a new `State.materialized?` flag. `AutoOrient` is the one exception — its need is data-determined (EXIF header), so it self-materializes internally. `DecodePlanner` always opens `:sequential`; the between-pipeline forced copy in `Request.Processor` is removed.

**Tech Stack:** Elixir, `Vix.Vips.Image` (libvips bindings), the `image` library wrappers, ExUnit, StreamData. Run everything through `mise exec -- mix ...`.

**Reference spec:** `docs/superpowers/specs/2026-06-02-sequential-access-per-op-materialization-design.md`

**Compile gate:** the project CI runs `mix compile --warnings-as-errors` and `mix credo --strict` (via `mise run precommit`). Every commit must pass `mise exec -- mix compile --warnings-as-errors`. Run focused tests with `mise exec -- mix test <file>`.

**Landing-order note (from spec §2):** Task 3 (callback + `__using__` macro + all 17 op conversions + facade) MUST land as one commit — the new required callback has no implementers until the macro injects the default, so splitting it breaks the compile.

---

## File Structure

**Modified — library:**
- `lib/image_pipe/transform/state.ex` — add `materialized?` field (Task 1)
- `lib/image_pipe/transform/materializer.ex` — State-level `materialize/1`, rewrite arity-2 body, moduledoc (Task 2)
- `lib/image_pipe/transform.ex` — `@callback` + `__using__` macro + facade dispatch (Task 3)
- All 17 modules in `lib/image_pipe/transform/operation/*.ex` — `@behaviour` → `use` (Task 3)
- `lib/image_pipe/transform/operation/{rotate,flip,crop}.ex` — `true` override clauses (Task 4)
- `lib/image_pipe/transform/operation/auto_orient.ex` — self-materialization (Task 5)
- `lib/image_pipe/transform/chain.ex` — `maybe_materialize/2` inside the op span (Task 6)
- `lib/image_pipe/transform/decode_planner.ex` — always `:sequential`, delete access selection (Task 7)
- `lib/image_pipe/request/processor.ex` — remove between-pipeline copy, simplify delivery (Task 8)

**Modified / deleted — tests:**
- `test/image_pipe/image_materializer_test.exs` — **deleted** (Task 2)
- `test/transform_chain_test.exs` — Layer 3 behaviour tests (Task 11)
- `test/image_pipe/decode_planner_test.exs`, `plug_test.exs`, `processor_test.exs` — update `:random` pins (Task 7)
- `test/image_pipe/imgproxy_wire_conformance_test.exs` — Layer 4 (Task 12)

**Created — tests:**
- `test/image_pipe/transform/sequential_access_test.exs` — Layer 1 + 2 (Tasks 9, 10)

---

## Task 1: Add `materialized?` field to `Transform.State`

**Files:**
- Modify: `lib/image_pipe/transform/state.ex`

- [ ] **Step 1: Add the field to the struct**

In `lib/image_pipe/transform/state.ex`, change the `defstruct` to add `materialized?: false`:

```elixir
defstruct image: nil,
          debug: false,
          detector: nil,
          detector_required: false,
          telemetry_opts: [],
          source_dimensions: nil,
          materialized?: false
```

- [ ] **Step 2: Add it to the `@type`**

```elixir
@type t :: %__MODULE__{
        image: Vix.Vips.Image.t() | nil,
        debug: boolean(),
        detector: module() | {module(), keyword()} | nil,
        detector_required: boolean(),
        telemetry_opts: keyword(),
        source_dimensions: {pos_integer(), pos_integer()} | nil,
        materialized?: boolean()
      }
```

- [ ] **Step 3: Compile and run the existing transform suite**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/transform_chain_test.exs`
Expected: PASS (additive field, defaults `false`, nothing reads it yet)

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/transform/state.ex
git commit -m "feat(transform): add State.materialized? flag"
```

---

## Task 2: `Materializer` — State-level `materialize/1`

The current `Materializer` has a `materialize/1` taking a `%VipsImage{}` and a `materialize/2` callback whose body delegates to `materialize(state.image)`. Replace the `VipsImage` form with a `State` form that sets `materialized?: true`, and rewrite the arity-2 body so it no longer calls the removed form.

**Files:**
- Modify: `lib/image_pipe/transform/materializer.ex`
- Delete: `test/image_pipe/image_materializer_test.exs`

- [ ] **Step 1: Write the failing test for the new State form**

Create `test/image_pipe/transform/materializer_test.exs`:

```elixir
defmodule ImagePipe.Transform.MaterializerStateTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State

  test "materialize/1 returns a memory-resident State with materialized?: true" do
    {:ok, image} = Image.new(32, 24, color: :white)
    state = %State{image: image, materialized?: false}

    assert {:ok, %State{} = result} = Materializer.materialize(state)
    assert result.materialized? == true
    assert Image.width(result.image) == 32
    assert Image.height(result.image) == 24
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/materializer_test.exs`
Expected: FAIL — `Materializer.materialize/1` currently takes a `%VipsImage{}`, so `materialize(%State{})` raises `FunctionClauseError`.

- [ ] **Step 3: Rewrite `materializer.ex`**

Replace the body of `lib/image_pipe/transform/materializer.ex` with:

```elixir
defmodule ImagePipe.Transform.Materializer do
  @moduledoc """
  Materialization boundary for transform execution.

  `materialize/1` copies the current image to a RAM-resident buffer via
  `Vix.Vips.Image.copy_memory/1` and marks the state `materialized?: true`.

  Per-op materialization (`ImagePipe.Transform.Chain`) calls this before the
  first operation that requires random access, so a sequential decode can stream
  through earlier ops and only copy when an op genuinely needs arbitrary pixel
  access. `Request.Processor` also calls the arity-2 callback form once before
  delivery for any chain that never materialized mid-pipeline.
  """

  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @callback materialize(State.t(), keyword()) ::
              {:ok, State.t()} | {:error, term()}

  @spec materialize(State.t()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{} = state) do
    case VipsImage.copy_memory(state.image) do
      {:ok, image} -> {:ok, %State{state | image: image, materialized?: true}}
      {:error, _reason} = error -> error
    end
  end

  @spec materialize(State.t(), keyword()) :: {:ok, State.t()} | {:error, term()}
  def materialize(%State{} = state, _opts) do
    materialize(state)
  end
end
```

- [ ] **Step 4: Delete the stale VipsImage-form test**

```bash
git rm test/image_pipe/image_materializer_test.exs
```

(It calls the removed `Materializer.materialize(image)` VipsImage form directly; per the spec it is deleted alongside the function, not kept alive to pin a removed entry point.)

- [ ] **Step 5: Run the new test + the processor suite**

Run: `mise exec -- mix test test/image_pipe/transform/materializer_test.exs test/image_pipe/processor_test.exs`
Expected: PASS. (The arity-2 callback signature is unchanged, so `Request.Processor.materialize_state` and the injectable stub still work.)

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/transform/materializer.ex test/image_pipe/transform/materializer_test.exs
git rm test/image_pipe/image_materializer_test.exs
git commit -m "feat(transform): Materializer.materialize/1 on State, set materialized?"
```

---

## Task 3: `Transform` behaviour — callback + `__using__` macro + convert 17 ops + facade

**This is one atomic commit** (compile constraint: the new required callback has no implementers until the macro injects the default).

**Files:**
- Modify: `lib/image_pipe/transform.ex`
- Modify all 17: `lib/image_pipe/transform/operation/{auto_orient,background,blur,brightness,contrast,crop,duotone,extend_canvas,flip,monochrome,normalize_color_profile,padding,pixelate,resize,rotate,saturation,sharpen}.ex`

- [ ] **Step 1: Write the failing test for the facade dispatch + default**

Create `test/image_pipe/transform/requires_materialization_test.exs`:

```elixir
defmodule ImagePipe.Transform.RequiresMaterializationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Blur

  test "default-classified ops do not require materialization" do
    refute Transform.requires_materialization?(%Background{color: [0, 0, 0, 255]})
    refute Transform.requires_materialization?(%Blur{sigma: 1.0})
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/requires_materialization_test.exs`
Expected: FAIL — `Transform.requires_materialization?/1` is undefined.

- [ ] **Step 3: Add the callback + `__using__` macro + facade to `transform.ex`**

In `lib/image_pipe/transform.ex`, add the callback next to the existing `@callback name/1` and `@callback execute/2`:

```elixir
@callback requires_materialization?(operation()) :: boolean()
```

Add the `__using__` macro (place it above `transform_name/1`):

```elixir
defmacro __using__(_opts) do
  quote do
    @behaviour ImagePipe.Transform

    @impl ImagePipe.Transform
    def requires_materialization?(_operation), do: false

    defoverridable requires_materialization?: 1
  end
end
```

Add the facade dispatch (next to `transform_name/1`):

```elixir
@spec requires_materialization?(operation()) :: boolean()
def requires_materialization?(%module{} = operation) do
  module.requires_materialization?(operation)
end
```

- [ ] **Step 4: Convert all 17 operation modules from `@behaviour` to `use`**

In each of these files, replace the line `@behaviour ImagePipe.Transform` with `use ImagePipe.Transform`:

```
lib/image_pipe/transform/operation/auto_orient.ex
lib/image_pipe/transform/operation/background.ex
lib/image_pipe/transform/operation/blur.ex
lib/image_pipe/transform/operation/brightness.ex
lib/image_pipe/transform/operation/contrast.ex
lib/image_pipe/transform/operation/crop.ex
lib/image_pipe/transform/operation/duotone.ex
lib/image_pipe/transform/operation/extend_canvas.ex
lib/image_pipe/transform/operation/flip.ex
lib/image_pipe/transform/operation/monochrome.ex
lib/image_pipe/transform/operation/normalize_color_profile.ex
lib/image_pipe/transform/operation/padding.ex
lib/image_pipe/transform/operation/pixelate.ex
lib/image_pipe/transform/operation/resize.ex
lib/image_pipe/transform/operation/rotate.ex
lib/image_pipe/transform/operation/saturation.ex
lib/image_pipe/transform/operation/sharpen.ex
```

Example (`flip.ex`), exact before/after:

```elixir
# before
@behaviour ImagePipe.Transform
# after
use ImagePipe.Transform
```

The existing `@impl ImagePipe.Transform` annotations on each module's `name/1` and `execute/2` remain valid — the macro injects `@behaviour ImagePipe.Transform`.

- [ ] **Step 5: Run the new test + full transform suite + warnings gate**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/image_pipe/transform/requires_materialization_test.exs test/transform_chain_test.exs`
Expected: PASS, zero warnings. (All 17 ops now have the default `false` clause via the macro; the facade dispatches.)

- [ ] **Step 6: Commit (atomic)**

```bash
git add lib/image_pipe/transform.ex lib/image_pipe/transform/operation/ test/image_pipe/transform/requires_materialization_test.exs
git commit -m "feat(transform): requires_materialization?/1 callback + __using__ default"
```

---

## Task 4: `true` override clauses on `Rotate`, `Flip`, `Crop`

**Files:**
- Modify: `lib/image_pipe/transform/operation/rotate.ex`
- Modify: `lib/image_pipe/transform/operation/flip.ex`
- Modify: `lib/image_pipe/transform/operation/crop.ex`

- [ ] **Step 1: Extend the test with the `true` cases**

Add to `test/image_pipe/transform/requires_materialization_test.exs` (add aliases for `Rotate`, `Flip`, `Crop` at the top):

```elixir
alias ImagePipe.Transform.Operation.Crop
alias ImagePipe.Transform.Operation.Flip
alias ImagePipe.Transform.Operation.Rotate

test "rotate requires materialization" do
  assert Transform.requires_materialization?(%Rotate{angle: 90})
  assert Transform.requires_materialization?(%Rotate{angle: 180})
  assert Transform.requires_materialization?(%Rotate{angle: 270})
end

test "vertical and both flips require materialization; horizontal does not" do
  assert Transform.requires_materialization?(%Flip{axis: :vertical})
  assert Transform.requires_materialization?(%Flip{axis: :both})
  refute Transform.requires_materialization?(%Flip{axis: :horizontal})
end

test "smart/detect crop requires materialization; anchor/focal does not" do
  assert Transform.requires_materialization?(%Crop{width: {:pixels, 10}, height: {:pixels, 10}, gravity: :smart})
  assert Transform.requires_materialization?(%Crop{width: {:pixels, 10}, height: {:pixels, 10}, gravity: {:smart, :face_assist}})
  assert Transform.requires_materialization?(%Crop{width: {:pixels, 10}, height: {:pixels, 10}, gravity: {:detect, {:all, %{}}}})
  refute Transform.requires_materialization?(%Crop{width: {:pixels, 10}, height: {:pixels, 10}, gravity: {:anchor, :center, :center}})
end
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `mise exec -- mix test test/image_pipe/transform/requires_materialization_test.exs`
Expected: FAIL — the new `assert`s fail (the ops still return the default `false`).

- [ ] **Step 3: Add the override clauses**

In `rotate.ex`, after the `name/1` clause add:

```elixir
@impl ImagePipe.Transform
def requires_materialization?(%__MODULE__{}), do: true
```

In `flip.ex`, after the `name/1` clause add:

```elixir
@impl ImagePipe.Transform
def requires_materialization?(%__MODULE__{axis: :horizontal}), do: false
def requires_materialization?(%__MODULE__{}), do: true
```

In `crop.ex`, after the `name/1` clause add:

```elixir
@impl ImagePipe.Transform
def requires_materialization?(%__MODULE__{gravity: :smart}), do: true
def requires_materialization?(%__MODULE__{gravity: {:smart, _}}), do: true
def requires_materialization?(%__MODULE__{gravity: {:detect, _}}), do: true
def requires_materialization?(%__MODULE__{}), do: false
```

- [ ] **Step 4: Run the test + warnings gate**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/image_pipe/transform/requires_materialization_test.exs`
Expected: PASS, zero warnings (each override carries `@impl ImagePipe.Transform`).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/operation/rotate.ex lib/image_pipe/transform/operation/flip.ex lib/image_pipe/transform/operation/crop.ex test/image_pipe/transform/requires_materialization_test.exs
git commit -m "feat(transform): Rotate/Flip/Crop declare materialization needs"
```

---

## Task 5: `AutoOrient` self-materialization

`AutoOrient` reads the EXIF orientation header; for orientations 3–8 (row-reversing/transposing) it materializes via `Materializer.materialize/1` then autorotates the materialized image; for 1/2 it streams. The struct-level `requires_materialization?` stays `false` (default) — the decision is data-determined, not struct-determined.

**Files:**
- Modify: `lib/image_pipe/transform/operation/auto_orient.ex`

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/transform/auto_orient_materialize_test.exs`:

```elixir
defmodule ImagePipe.Transform.AutoOrientMaterializeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.AutoOrient
  alias ImagePipe.Transform.State

  defp oriented_state(orientation) do
    {:ok, image} = Image.new(40, 20, color: :red)
    image = Image.set_orientation!(image, orientation)
    %State{image: image, materialized?: false}
  end

  test "quarter-turn EXIF (6) materializes and swaps dimensions" do
    {:ok, %State{} = result} = AutoOrient.execute(%AutoOrient{}, oriented_state(6))

    assert result.materialized? == true
    # orientation 6 is a 90-degree turn: 40x20 displays as 20x40
    assert Image.width(result.image) == 20
    assert Image.height(result.image) == 40
  end

  test "row-reversing EXIF (3, 180) materializes without axis swap" do
    {:ok, %State{} = result} = AutoOrient.execute(%AutoOrient{}, oriented_state(3))

    assert result.materialized? == true
    assert Image.width(result.image) == 40
    assert Image.height(result.image) == 20
  end

  test "identity EXIF (1) streams without materializing" do
    {:ok, %State{} = result} = AutoOrient.execute(%AutoOrient{}, oriented_state(1))

    assert result.materialized? == false
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/auto_orient_materialize_test.exs`
Expected: FAIL — current `AutoOrient.execute` never sets `materialized?`, so the `== true` assertions fail.

- [ ] **Step 3: Rewrite `auto_orient.ex`'s `execute/2` + add the materialize helper**

Add `alias ImagePipe.Transform.Materializer` and `alias Vix.Vips.Image, as: VipsImage` near the existing aliases, then replace the `execute/2` clause and add the private helpers:

```elixir
@impl ImagePipe.Transform
def execute(%__MODULE__{}, %State{} = state) do
  pre_width = Image.width(state.image)

  with {:ok, %State{} = state} <- maybe_materialize_for_orientation(state),
       {:ok, {image, _flags}} <- Image.autorotate(state.image) do
    {:ok, sync_source_dimensions(set_image(state, image), pre_width, Image.width(image))}
  else
    {:error, error} -> {:error, {__MODULE__, error}}
  end
end

# EXIF orientations 3 (180), 4 (vflip), 5/7 (transpose/transverse), 6/8 (90/270)
# reverse row order or transpose axes and need random access; 1 (identity) and 2
# (pure hflip) stream. We materialize the source buffer first so the lazy
# autorotate node has random access to it.
defp maybe_materialize_for_orientation(%State{} = state) do
  case orientation(state.image) do
    o when o in [3, 4, 5, 6, 7, 8] -> Materializer.materialize(state)
    _ -> {:ok, state}
  end
end

defp orientation(image) do
  case VipsImage.header_value(image, "orientation") do
    {:ok, value} when is_integer(value) -> value
    _ -> 1
  end
end
```

(Keep the existing `sync_source_dimensions/3` private clauses unchanged.)

- [ ] **Step 4: Run the test + warnings gate**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/image_pipe/transform/auto_orient_materialize_test.exs`
Expected: PASS, zero warnings. (There is no dedicated `auto_orient_test.exs`; AutoOrient's broader coverage lives in the wire/conformance and shrink suites, exercised by `mise run precommit` at the end.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/operation/auto_orient.ex test/image_pipe/transform/auto_orient_materialize_test.exs
git commit -m "feat(transform): AutoOrient self-materializes for EXIF 3-8"
```

> **Gate (spec §7):** the exact safe set is provisional. Task 9's streaming equivalence test is the real gate — if a sequential autorotate for any of orientations 3–8 raises or diverges in a way the in-memory test cannot see, keep it in the materialize set (already the conservative default). If orientation 2 (hflip) ever fails the streaming test, add it to the set.

---

## Task 6: `Chain` — inline `maybe_materialize` inside the op span

**Files:**
- Modify: `lib/image_pipe/transform/chain.ex`

- [ ] **Step 1: Add the `Materializer` alias and the helper**

In `lib/image_pipe/transform/chain.ex`, add `alias ImagePipe.Transform.Materializer` next to the existing aliases, then add this private helper at the bottom of the module:

```elixir
defp maybe_materialize(%State{materialized?: true} = state, _operation), do: {:ok, state}

defp maybe_materialize(%State{} = state, operation) do
  if Transform.requires_materialization?(operation) do
    Materializer.materialize(state)
  else
    {:ok, state}
  end
end
```

- [ ] **Step 2: Call it inside the telemetry span**

Replace the `Enum.reduce_while` body in `execute/3` so `maybe_materialize` runs inside the `[:transform, :operation]` span, before `Transform.execute`:

```elixir
transform_chain
|> Enum.with_index()
|> Enum.reduce_while({:ok, state}, fn {operation, index}, {:ok, state} ->
  name = Transform.transform_name(operation)

  result =
    Telemetry.span(
      telemetry_opts,
      [:transform, :operation],
      %{operation: name, index: index, params: operation},
      fn ->
        res =
          with {:ok, state} <- maybe_materialize(state, operation) do
            Transform.execute(operation, state)
          end

        {res, %{result: elem(res, 0)}}
      end
    )

  case result do
    {:ok, %State{} = next_state} -> {:cont, {:ok, next_state}}
    {:error, reason} -> {:halt, {:error, {:transform_error, reason}}}
  end
end)
```

- [ ] **Step 3: Run the chain suite + warnings gate**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/transform_chain_test.exs`
Expected: PASS. (DecodePlanner still opens `:random` until Task 7, so per-op materialization is a redundant-but-harmless extra copy on an already-random image — correctness is preserved.)

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/transform/chain.ex
git commit -m "feat(transform): Chain materializes per-op inside the op span"
```

---

## Task 7: `DecodePlanner` — always `:sequential`, delete access selection

**Files:**
- Modify: `lib/image_pipe/transform/decode_planner.ex`
- Modify: `test/image_pipe/decode_planner_test.exs`
- Modify: `test/image_pipe/plug_test.exs`
- Modify: `test/image_pipe/processor_test.exs`

- [ ] **Step 1: Update the planner tests first (they pin the old `:random` values)**

In `test/image_pipe/decode_planner_test.exs`, the "Access selection" block asserts `:random` for the empty chain, neutral-alone (`NormalizeColorProfile`), and composition/crop chains. Change every `assert opts[:access] == :random` / `assert ... == :random` in that block to `:sequential`. (Find each with the grep below.)

Run to locate them:
`mise exec -- grep -rn "access.*:random\|:random.*access" test/image_pipe/decode_planner_test.exs test/image_pipe/plug_test.exs test/image_pipe/processor_test.exs`

- In `test/image_pipe/plug_test.exs` (~line 1858, "cover opens origin with random access"): change the asserted `access == :random` to `:sequential` and rename the test to "...with sequential access". **Only this one test flips.** Leave the `header_opts` assertions (the header probe at `processor.ex` hardcodes `access: :random` — unaffected; ~lines 1852/1887/1913) and any `metadata` stub `%{access: :random}` (~line 351) **unchanged**. Do not blanket-replace `:random` in this file.
- In `test/image_pipe/processor_test.exs` (~line 120): change `assert decoded.decode_options == [access: :random, fail_on: :error]` to `[access: :sequential, fail_on: :error]`.

- [ ] **Step 2: Run the tests to verify they now fail (planner still returns `:random`)**

Run: `mise exec -- mix test test/image_pipe/decode_planner_test.exs`
Expected: FAIL — assertions now expect `:sequential` but `open_options` still computes `access(chain)`.

- [ ] **Step 3: Change `open_options/4` to always `:sequential` and delete the access-selection code**

In `lib/image_pipe/transform/decode_planner.ex`:

Change the `base` line in `open_options/4`:

```elixir
# before
base = [access: access(chain), fail_on: :error]
# after
base = [access: :sequential, fail_on: :error]
```

Delete the entire "Access selection" section — these private functions and the dead type:
- `@type access_requirement() :: ...`
- `defp access([])` and `defp access(chain)`
- all `defp access_requirement/1` clauses
- `defp resize_access_requirement/1` (both clauses)
- `defp requested_resize_dimension?/1` (both clauses)
- `defp resolve_access/1`

**Then remove the 13 `alias` lines that only those deleted functions referenced** — otherwise `--warnings-as-errors` fails on unused aliases. Delete exactly these aliases (they are the plan-op modules only `access_requirement/1` named):

```
alias ImagePipe.Plan.Operation.Background
alias ImagePipe.Plan.Operation.Blur
alias ImagePipe.Plan.Operation.Brightness
alias ImagePipe.Plan.Operation.Canvas
alias ImagePipe.Plan.Operation.Contrast
alias ImagePipe.Plan.Operation.Duotone
alias ImagePipe.Plan.Operation.Flip
alias ImagePipe.Plan.Operation.Monochrome
alias ImagePipe.Plan.Operation.NormalizeColorProfile
alias ImagePipe.Plan.Operation.Padding
alias ImagePipe.Plan.Operation.Pixelate
alias ImagePipe.Plan.Operation.Saturation
alias ImagePipe.Plan.Operation.Sharpen
```

Keep the aliases still used by the shrink-on-load code: `AutoOrient`, `CropGuided`, `CropRegion`, `Resize` (as `PlanResize`), `Rotate`. Keep the `@type source_format()` (still used in the `@spec`).

Update the moduledoc paragraph that describes the binary access decision to say decode is always sequential and random access is provided per-op by `ImagePipe.Transform.Chain`.

- [ ] **Step 4: Run the updated tests + full planner/plug/processor suites + warnings gate**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/image_pipe/decode_planner_test.exs test/image_pipe/processor_test.exs`
Expected: PASS, zero warnings (no unused-function warnings — everything in the access subtree was deleted together).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/decode_planner.ex test/image_pipe/decode_planner_test.exs test/image_pipe/plug_test.exs test/image_pipe/processor_test.exs
git commit -m "feat(transform): DecodePlanner always opens sequential"
```

---

## Task 8: `Request.Processor` — remove between-pipeline copy, simplify delivery

**Files:**
- Modify: `lib/image_pipe/request/processor.ex`

- [ ] **Step 1: Simplify `materialize_before_delivery` to drop the `decode_options` branch**

Replace the existing `materialize_before_delivery/4` with this `/3` form:

```elixir
defp materialize_before_delivery(%State{} = state, opts, source_response) do
  result =
    if state.materialized? do
      {:ok, state}
    else
      materialize_state(state, opts)
    end

  handle_materialization_result(result, source_response)
end
```

Update its call site (currently `materialize_before_delivery(final_state, decode_options, opts, source_response)`) to drop `decode_options`:

```elixir
materialize_before_delivery(final_state, opts, source_response)
```

- [ ] **Step 2: Remove the between-pipeline materialization**

Delete the private functions `maybe_materialize_between_pipelines/5` and `materialize_between_pipelines/3`. Simplify `execute_plan_pipeline_step` so each pipeline runs and threads its state with no forced copy between pipelines:

```elixir
defp execute_plan_pipeline_step({pipeline, _index}, {:ok, %State{} = state}, _last_index, %Plan{} = plan, opts, _source_response) do
  case Transform.execute_plan(%Plan{plan | pipelines: [pipeline]}, state, opts) do
    {:ok, %State{} = state} -> {:cont, {:ok, state}}
    {:error, _reason} = error -> {:halt, error}
  end
end
```

The caller `execute_plan_pipelines/4` currently computes `last_index = length(pipelines) - 1` and threads `last_index` + `source_response` into the step purely for the between-pipeline check. Since the step now ignores them, drop the now-dead `last_index` binding and stop threading it (and `source_response` if it becomes unused) so `--warnings-as-errors` stays green. Simplify the `Enum.reduce_while` over `pipelines` to call `execute_plan_pipeline_step` with just `{pipeline, index}`, the acc, and `plan`/`opts`. Adjust the step function's arity to match whatever you keep — the key is: no unused bindings remain.

- [ ] **Step 3: Remove the obsolete between-pipeline tests**

The between-pipeline behavior is gone, so the tests pinning it must go (greenfield: delete behavior for removed paths). Locate them:

Run: `mise exec -- grep -rn "materialized_between_pipelines\|between pipelines\|between_pipelines" test/`

Delete the test asserting `assert_receive {:pipeline_event, ^ref, :materialized_between_pipelines}` in `test/image_pipe/processor_test.exs` (~line 122, "materializes between pipelines") and any equivalent in `test/image_pipe/request_runner_test.exs` (~line 1199). If the support stub `test/support/image_pipe/request_processor_test/materializer.ex` only existed to emit that `:materialized_between_pipelines` event, simplify it to a plain pass-through `materialize/2` (or leave it — it now only fires from the delivery-path `materialize_state`, which is harmless, but the misnamed event should not be asserted anywhere).

- [ ] **Step 4: Run the processor + plug suites + warnings gate**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/image_pipe/processor_test.exs test/image_pipe/plug_test.exs`
Expected: PASS, zero warnings. (Multi-pipeline plans now rely on per-op materialization within each pipeline's `Chain.execute`; the state's `materialized?` flag threads pipeline to pipeline.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/request/processor.ex test/image_pipe/processor_test.exs test/image_pipe/request_runner_test.exs test/support/image_pipe/request_processor_test/materializer.ex
git commit -m "feat(request): drop between-pipeline copy; per-op materialization end to end"
```

---

## Task 9: Layer 1 — per-op sequential-vs-random equivalence tests

Resurrect the streaming harness from the deleted `sequential_compatibility_test.exs` (recovered via `git show a0e26ed~1:test/image_pipe/sequential_compatibility_test.exs`) and extend it to every `false`-classified op. **The source must genuinely stream** — open from a stream list with `access: :sequential` and `fail_on: :error`. An in-memory `from_binary` would buffer and make the comparison a tautology.

**Files:**
- Create: `test/image_pipe/transform/sequential_access_test.exs`

- [ ] **Step 1: Create the test file with the streaming harness + a harness self-check**

```elixir
defmodule ImagePipe.Transform.SequentialAccessTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Blur
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Flip
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Operation.Sharpen
  alias ImagePipe.Transform.State

  @beach "priv/static/images/beach.jpg"
  @dog "priv/static/images/dog.jpg"

  # Harness self-check: prove the sequential open GENUINELY streams (does not
  # silently buffer). A 90-degree transpose built directly on the sequential
  # image — bypassing Chain, which would materialize first — must error when its
  # pixels are pulled, because vips_rot does a non-sequential read. If copy_memory
  # succeeds here, the open is buffering and every equivalence assertion below
  # would be a tautology.
  test "sequential open genuinely streams (a raw transpose errors at evaluation)" do
    body = File.read!(@beach)
    {:ok, image} = Image.open([body], access: :sequential, fail_on: :error)
    {:ok, rotated} = Image.rotate(image, 90)

    assert {:error, _reason} = Vix.Vips.Image.copy_memory(rotated)
  end

  defp alpha_png_body do
    {:ok, image} = Image.new(320, 180, color: [0, 255, 0, 255], bands: 4)
    Image.write!(image, :memory, suffix: ".png")
  end

  defp run_chain(chain, access, body) when access in [:random, :sequential] do
    with {:ok, image} <- Image.open([body], access: access, fail_on: :error),
         {:ok, state} <- Chain.execute(%State{image: image}, chain),
         {:ok, %State{} = state} <- Materializer.materialize(state) do
      {:ok, state.image}
    end
  end

  defp assert_sequential_matches_random(chain, body) do
    {:ok, random_image} = run_chain(chain, :random, body)
    {:ok, sequential_image} = run_chain(chain, :sequential, body)

    assert Image.width(sequential_image) == Image.width(random_image)
    assert Image.height(sequential_image) == Image.height(random_image)
    assert Image.has_alpha?(sequential_image) == Image.has_alpha?(random_image)
    assert_sampled_pixels_match(sequential_image, random_image)
  end

  defp assert_sampled_pixels_match(left, right) do
    for x <- sample_positions(Image.width(left)),
        y <- sample_positions(Image.height(left)) do
      assert Image.get_pixel!(left, x, y) == Image.get_pixel!(right, x, y)
    end
  end

  defp sample_positions(size) do
    last = max(size - 1, 0)
    Enum.uniq([0, div(last, 4), div(last, 2), div(last * 3, 4), last])
  end
end
```

- [ ] **Step 2: Run the harness self-check to verify it actually streams**

Run: `mise exec -- mix test test/image_pipe/transform/sequential_access_test.exs`
Expected: PASS — the `Rotate 90` self-check raises as required. (If it does NOT raise, stop: the harness is buffering and the rest of the layer is meaningless. The `image` library version pinned in `mise`/`mix.lock` is the one the deleted test proved this against.)

- [ ] **Step 3: Add one equivalence test per `false`-classified op**

Add these tests to the module:

```elixir
test "anchor crop streams" do
  assert_sequential_matches_random(
    [%Crop{width: {:pixels, 80}, height: {:pixels, 60}, crop_from: :gravity, gravity: {:anchor, :center, :center}}],
    File.read!(@beach)
  )
end

test "fit resize streams" do
  assert_sequential_matches_random([%Resize{mode: :fit, width: {:pixels, 120}, height: :auto}], File.read!(@dog))
end

test "force resize streams" do
  assert_sequential_matches_random([%Resize{mode: :force, width: {:pixels, 100}, height: {:pixels, 100}}], File.read!(@beach))
end

test "horizontal flip streams" do
  assert_sequential_matches_random([%Flip{axis: :horizontal}], File.read!(@beach))
end

test "blur streams" do
  assert_sequential_matches_random([%Blur{sigma: 2.0}], File.read!(@beach))
end

test "sharpen streams" do
  assert_sequential_matches_random([%Sharpen{sigma: 1.5}], File.read!(@beach))
end

test "background flatten streams (alpha png)" do
  assert_sequential_matches_random([%Background{color: [255, 0, 0, 255]}], alpha_png_body())
end

test "padding streams" do
  assert_sequential_matches_random([%Padding{top: 10, right: 10, bottom: 10, left: 10, fill: :transparent}], File.read!(@beach))
end

test "canvas extend streams" do
  assert_sequential_matches_random(
    [%ExtendCanvas{rule: {:dimensions, {:pixels, 400}, {:pixels, 400}}, gravity: {:anchor, :center, :center}, background: :transparent}],
    File.read!(@beach)
  )
end

test "pixelate streams" do
  assert_sequential_matches_random([%Pixelate{size: 8}], File.read!(@beach))
end

test "brightness streams" do
  assert_sequential_matches_random([%Brightness{value: 20}], File.read!(@beach))
end

test "contrast streams" do
  assert_sequential_matches_random([%Contrast{value: 15}], File.read!(@beach))
end

test "saturation streams" do
  assert_sequential_matches_random([%Saturation{value: 25}], File.read!(@beach))
end

test "monochrome streams" do
  assert_sequential_matches_random([%Monochrome{intensity: 0.8, color: [179, 179, 179]}], File.read!(@beach))
end

test "duotone streams" do
  assert_sequential_matches_random([%Duotone{intensity: 0.8, shadow: [0, 0, 0], highlight: [255, 255, 255]}], File.read!(@beach))
end

test "normalize color profile streams" do
  assert_sequential_matches_random([%NormalizeColorProfile{}], File.read!(@beach))
end
```

- [ ] **Step 3b: Add the AutoOrient streaming-equivalence cases (the §7 gate)**

AutoOrient is the op whose classification this layer most needs to validate — its self-materialize logic runs on a genuinely streamed source here, which the in-memory unit test in Task 5 cannot exercise. Add `alias ImagePipe.Transform.Operation.AutoOrient` and a synthesized-oriented-body helper, then one case per EXIF orientation:

```elixir
defp oriented_jpeg_body(orientation) do
  {:ok, image} = Image.new(120, 80, color: :red)
  image
  |> Image.set_orientation!(orientation)
  |> Image.write!(:memory, suffix: ".jpg")
end

for orientation <- [1, 2, 3, 4, 5, 6, 7, 8] do
  @orientation orientation
  test "auto-orient streams for EXIF orientation #{orientation}" do
    assert_sequential_matches_random([%AutoOrient{}], oriented_jpeg_body(@orientation))
  end
end
```

This drives `[%AutoOrient{}]` through the streamed `:sequential` open vs `:random`: orientations 3–8 self-materialize then autorotate; 1/2 stream. If any orientation in the materialize set (3–8) diverges or raises, it stays in the set (conservative default, already the case). If orientation 2 diverges, add it to `auto_orient.ex`'s materialize set (Task 5) and re-run. (The shrink-active variant — orientation + a residual resize — is exercised end-to-end by `mise run precommit`'s shrink/conformance suites; this layer pins the bare orientation path.)

Add the corresponding aliases at the top of the module: `AutoOrient`, `Brightness`, `Contrast`, `Saturation`, `Monochrome`, `Duotone`, `Pixelate`, `NormalizeColorProfile` (all under `ImagePipe.Transform.Operation.*`). These are the exact executable struct shapes `PlanExecutor` builds (`Brightness`/`Contrast`/`Saturation` take a numeric `value`; `Monochrome` takes `intensity` 0..1 + RGB `color`; `Duotone` takes `intensity` + RGB `shadow`/`highlight`; `Pixelate` takes integer `size`; `NormalizeColorProfile` has no fields).

- [ ] **Step 4: Run the full Layer 1 file**

Run: `mise exec -- mix test test/image_pipe/transform/sequential_access_test.exs`
Expected: PASS for every op. **If `Flip{horizontal}` fails** (raises or pixels diverge), change `flip.ex`'s `requires_materialization?(%Flip{axis: :horizontal})` to `true` (Task 4), re-run Task 4's test, and remove the horizontal-flip equivalence test (it's then a `true` op, not covered by Layer 1). Note this in the commit.

- [ ] **Step 5: Commit**

```bash
git add test/image_pipe/transform/sequential_access_test.exs
git commit -m "test(transform): per-op sequential-vs-random equivalence (Layer 1)"
```

---

## Task 10: Layer 2 — property tests over geometry space

**Files:**
- Modify: `test/image_pipe/transform/sequential_access_test.exs`

- [ ] **Step 1: Add `StreamData` property tests to the same module**

Add `use ExUnitProperties` under `use ExUnit.Case` at the top, then add:

```elixir
property "anchor crop streams across varied dimensions and anchors" do
  body = File.read!(@beach)

  check all w <- integer(8..200),
            h <- integer(8..150),
            anchor <- member_of([:center, :left, :right, :top, :bottom, :top_left, :bottom_right]),
            max_runs: 25 do
    {ax, ay} = anchor_to_xy(anchor)
    assert_sequential_matches_random(
      [%Crop{width: {:pixels, w}, height: {:pixels, h}, crop_from: :gravity, gravity: {:anchor, ax, ay}}],
      body
    )
  end
end

property "fit resize streams across varied targets" do
  body = File.read!(@dog)

  check all w <- integer(16..400), max_runs: 25 do
    assert_sequential_matches_random([%Resize{mode: :fit, width: {:pixels, w}, height: :auto}], body)
  end
end

property "blur streams across varied sigma" do
  body = File.read!(@beach)

  check all sigma_tenths <- integer(5..40), max_runs: 20 do
    assert_sequential_matches_random([%Blur{sigma: sigma_tenths / 10}], body)
  end
end

property "horizontal flip streams across image sizes" do
  check all w <- integer(20..200), h <- integer(20..200), max_runs: 20 do
    {:ok, image} = Image.new(w, h, color: [10, 120, 200])
    body = Image.write!(image, :memory, suffix: ".png")
    assert_sequential_matches_random([%Flip{axis: :horizontal}], body)
  end
end

property "auto-orient streams across EXIF orientations and sizes" do
  check all orientation <- member_of([1, 2, 3, 4, 5, 6, 7, 8]),
            w <- integer(20..160),
            h <- integer(20..160),
            max_runs: 24 do
    {:ok, image} = Image.new(w, h, color: :red)
    body = image |> Image.set_orientation!(orientation) |> Image.write!(:memory, suffix: ".jpg")
    assert_sequential_matches_random([%AutoOrient{}], body)
  end
end
```

Add the `anchor_to_xy/1` helper:

```elixir
defp anchor_to_xy(:center), do: {:center, :center}
defp anchor_to_xy(:left), do: {:left, :center}
defp anchor_to_xy(:right), do: {:right, :center}
defp anchor_to_xy(:top), do: {:center, :top}
defp anchor_to_xy(:bottom), do: {:center, :bottom}
defp anchor_to_xy(:top_left), do: {:left, :top}
defp anchor_to_xy(:bottom_right), do: {:right, :bottom}
```

- [ ] **Step 2: Run the property tests**

Run: `mise exec -- mix test test/image_pipe/transform/sequential_access_test.exs`
Expected: PASS. (Property tests are the real gate for blur/sharpen, where imgproxy gives no evidence — if any property finds a streaming divergence, that op's classification must flip to `true`.)

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/transform/sequential_access_test.exs
git commit -m "test(transform): property tests over geometry for sequential-safety (Layer 2)"
```

---

## Task 11: Layer 3 — Chain materialization behaviour tests

**Files:**
- Modify: `test/transform_chain_test.exs`

- [ ] **Step 1: Add behaviour tests asserting on the observable `materialized?` contract**

Add to `test/transform_chain_test.exs` (add aliases for `Rotate` and `Background` if not present):

```elixir
describe "per-op materialization" do
  test "a chain with a materializing op sets materialized? and stays correct" do
    {:ok, image} = Image.new(40, 20, color: :white)
    {:ok, state} = Chain.execute(%State{image: image, materialized?: false}, [%Rotate{angle: 90}])

    assert state.materialized? == true
    assert Image.width(state.image) == 20
    assert Image.height(state.image) == 40
  end

  test "a second materializing op produces correct output (no double-copy regression)" do
    {:ok, image} = Image.new(40, 20, color: :white)
    {:ok, state} = Chain.execute(%State{image: image, materialized?: false}, [%Rotate{angle: 90}, %Rotate{angle: 90}])

    # two 90-degree turns = 180; back to 40x20
    assert state.materialized? == true
    assert Image.width(state.image) == 40
    assert Image.height(state.image) == 20
  end

  test "a fully sequential-safe chain leaves materialized? false" do
    {:ok, image} = Image.new(40, 20, color: :white)
    {:ok, state} = Chain.execute(%State{image: image, materialized?: false}, [%Background{color: [0, 0, 0, 255]}])

    assert state.materialized? == false
  end
end
```

- [ ] **Step 2: Run the chain suite**

Run: `mise exec -- mix test test/transform_chain_test.exs`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/transform_chain_test.exs
git commit -m "test(transform): Chain materialized? behaviour contract (Layer 3)"
```

---

## Task 12: Layer 4 — wire conformance additions

**Files:**
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Add representative end-to-end cases for now-sequential chains**

Add wire-level tests that make real `ImagePipe.call/2` requests and assert on decoded output dimensions and representative pixels (not byte-identity), following the existing conformance-test patterns in that file (origin plug, request path building, `Image.open` of the response body). Add three cases:

- **Anchor crop + blur** (previously forced random by blur): a fixed-gravity crop with `bl:` blur; assert the decoded output dimensions match the crop and the body decodes.
- **Resize cover + canvas + padding + background**: a `rs:fill` + extend + `pd:` padding + `bg:` request; assert final dimensions include the padding and the background fill shows at a corner pixel.
- **Transparent source + blur + background**: an alpha source with `bl:` + `bg:`; assert the output has no alpha (flattened) and the corner pixel is the background color.

**Before writing, confirm the exact imgproxy option tokens against this file and the parser** — the existing tests use `bl:` (blur), `pix:`, `mc:`/`dt:`, `br:`/`co:`/`sa:`, and `exar:` for aspect-ratio extend; padding/extend token spellings (`pd:`, `ex:`) must be verified in `ImagePipe.Parser.Imgproxy` or an existing test before use (grep the test file for a working example of each). Build each request path from a confirmed literal, e.g. the crop+blur case as a single string like:

```elixir
# confirm gravity/crop/blur token spellings against existing tests first
path = "/unsafe/c:80:60/g:ce/bl:4/plain/" <> URI.encode_www_form(origin_url) <> "@png"
```

Use the file's existing request-issuing helper (the `ImagePipe.call/2` wrapper / `conn` builder the other tests use — grep for `ImagePipe.call` to find it) rather than re-deriving the conn setup.

**The transparent-source case needs an alpha origin plug** — the existing effect/origin plugs in this file are opaque. Author a small origin module that serves an RGBA PNG (e.g. `Image.new!(20, 20, color: [0, 255, 0, 0], bands: 4) |> Image.write!(:memory, suffix: ".png")`), mirroring the existing `defmodule ...OriginImage` plugs at the top of the file. The `alpha_png_body/0` helper from Task 9 lives in a different test file and is not reusable here.

> Assert with `Image.open(body)` + `Image.get_pixel!/3` + `Image.width/height` + `Image.has_alpha?/1`, matching the file's existing assertion style.

These three cases are PASS-only (no red step) because they exercise full end-to-end paths that already work for the random decode; the value is confirming they still produce correct output now that the chain runs sequentially. To make the green meaningful, assert a *specific* expected dimension/pixel (not just "the body decodes").

- [ ] **Step 2: Run the conformance suite**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(imgproxy): wire conformance for now-sequential chains (Layer 4)"
```

---

## Task 13: Delivery-path materialization for fully-sequential plans

**Scope correction (from plan review):** the earlier framing — "a late source-stream error surfaces at delivery" — pins the wrong path. Stream sources are drained eagerly at `seekable_input` (decode time), so their body-limit/stream errors surface at decode, already covered by the existing `decode_validate_source_response` source-error tests (`grep -n "{:source" test/image_pipe/processor_test.exs`). Path sources never set those flags; a truncated path read is a legitimate decode error (spec §6). So there is **no late source error to pin at delivery**.

What *does* need pinning is the §6 simplification itself: a fully sequential-safe single-pipeline plan reaches delivery with `materialized? == false`, and `materialize_before_delivery` must still materialize it so the encoder gets a RAM-resident image. If that copy were dropped, the response would carry a lazy image that fails at encode.

**Files:**
- Modify: `test/image_pipe/processor_test.exs`

- [ ] **Step 1: Add the end-to-end sequential-delivery test**

Add a test that drives a full request through `process_source/3` (the entry point that reaches `materialize_before_delivery`) with a plan that has **no** materializing op (a plain `rs:fit` resize on a small target — fully sequential, `materialized? == false` until delivery), and asserts the response is a successful, **decodable** image of the expected dimensions. Mirror the existing `process_source/3` happy-path test in this file (the one using `resolved_source()` / `fetch: :fixture`) for the request and source shape; assert `{:ok, ...}` and that `Image.open(response_body)` yields the expected width/height.

> This proves the simplified delivery materialize still runs for a never-mid-chain-materialized plan. Source-error surfacing for streams is already covered at decode — do not duplicate it here, and do not assert `{:source, _}` (no source error reaches delivery in the sequential path).

- [ ] **Step 2: Run the suite**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs`
Expected: PASS — the sequential plan returns a decodable image at the resize target dimensions.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/processor_test.exs
git commit -m "test(request): sequential-plan delivery materializes before encode"
```

---

## Final verification

- [ ] **Run the full Elixir gate**

Run: `mise run precommit`
(Runs `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`.)
Expected: all green.

- [ ] **Confirm architecture boundaries unaffected**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS (all new dispatch is intra-`ImagePipe.Transform` boundary; no request/source/response code names a concrete operation module).
