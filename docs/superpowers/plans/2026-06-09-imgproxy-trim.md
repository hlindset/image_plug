# imgproxy `trim` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an imgproxy-compatible `trim`/`t` option that detects and removes a uniform-color border from the source image, at full parity (threshold, color, equal_hor, equal_ver).

**Architecture:** A new semantic `Plan.Operation.Trim` (product-neutral) translated by `PlanExecutor` to an executable `Transform.Operation.Trim` that faithfully replicates imgproxy's `vips_trim` (sRGB-convert → magenta-flatten alpha → top-left smart bg → `find_trim` → equal_hor/ver box symmetrization → no-op on degenerate box → extract from the original). The imgproxy parser emits the semantic op; it is positioned first in the geometry order; trim in the first pipeline disables shrink-on-load.

**Tech Stack:** Elixir, the `image` Hex lib + `Vix.Vips.Operation` (libvips), ExUnit + StreamData, Boundary.

**Spec:** `docs/superpowers/specs/2026-06-09-imgproxy-trim-design.md`

**Conventions:**
- Run everything through `mise exec -- ...` (e.g. `mise exec -- mix test path`).
- TDD: write the failing test, run it red, implement, run it green, commit.
- Reference the spec's "Behavioral divergences" for the deliberate imgproxy gaps.

---

## File map

| File | Responsibility | Action |
| --- | --- | --- |
| `lib/image_pipe/plan/operation/trim.ex` | Semantic Trim struct | Create |
| `lib/image_pipe/plan/operation.ex` | `trim/1` factory, `semantic?/1` clause | Modify |
| `lib/image_pipe/plan/key_data.ex` | `data(%Trim{})` cache-key clause | Modify |
| `lib/image_pipe/plan.ex` | Boundary export of `Plan.Operation.Trim` | Modify |
| `lib/image_pipe/transform/operation/trim.ex` | Executable Trim op (replicates `vips_trim`) | Create |
| `lib/image_pipe/transform.ex` | Boundary export of `Transform.Operation.Trim` | Modify |
| `lib/image_pipe/transform/plan_executor.ex` | `PlanTrim → Trim` translation clause | Modify |
| `lib/image_pipe/transform/decode_planner.ex` | Trim in chain ⇒ block shrink-on-load | Modify |
| `lib/image_pipe/parser/imgproxy/pipeline_request.ex` | `trim` field | Modify |
| `lib/image_pipe/parser/imgproxy/option_grammar.ex` | `trim`/`t` parse | Modify |
| `lib/image_pipe/parser/imgproxy/options.ex` | apply `{:trim, …}` to pipeline | Modify |
| `lib/image_pipe/parser/imgproxy/plan_builder.ex` | emit `Operation.trim` first in geometry | Modify |
| `test/image_pipe/architecture_boundary_test.exs` | export-list assertions | Modify |
| `docs/imgproxy_support_matrix.md` | conformance doc (3 axes) | Modify |
| `demo/` | trim controls + URL state | Modify |
| test files (several) | TDD coverage | Create/Modify |

---

## Task 1: Semantic `Plan.Operation.Trim` struct + factory + validation

**Files:**
- Create: `lib/image_pipe/plan/operation/trim.ex`
- Modify: `lib/image_pipe/plan/operation.ex`
- Test: `test/image_pipe/plan/operation_test.exs` (add cases; create if absent — check first with `ls test/image_pipe/plan/`)

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/plan/operation_test.exs` (mirror the existing `background`/`padding` factory tests in that file; if the file does not exist, create it with `use ExUnit.Case, async: true` and `alias ImagePipe.Plan.{Operation, Color}`):

```elixir
describe "trim/1" do
  test "builds a smart (:auto background) trim" do
    assert {:ok, %Operation.Trim{
              threshold: 12.0,
              background: :auto,
              equal_hor: false,
              equal_ver: false
            }} =
             Operation.trim(threshold: 12.0, background: :auto)
  end

  test "builds an explicit-color trim with equal flags" do
    {:ok, color} = Color.rgb(255, 0, 255)

    assert {:ok, %Operation.Trim{threshold: 5.0, background: ^color, equal_hor: true, equal_ver: true}} =
             Operation.trim(threshold: 5.0, background: color, equal_hor: true, equal_ver: true)
  end

  test "rejects a non-numeric threshold" do
    assert {:error, {:invalid_operation, :trim, _}} = Operation.trim(threshold: "x", background: :auto)
  end

  test "rejects a non-color, non-:auto background" do
    assert {:error, {:invalid_operation, :trim, _}} = Operation.trim(threshold: 1.0, background: :nope)
  end

  test "semantic? accepts a valid Trim and rejects a malformed one" do
    {:ok, op} = Operation.trim(threshold: 1.0, background: :auto)
    assert Operation.semantic?(op)
    refute Operation.semantic?(%Operation.Trim{threshold: "x", background: :auto, equal_hor: false, equal_ver: false})
  end
end
```

- [ ] **Step 2: Run it red**

Run: `mise exec -- mix test test/image_pipe/plan/operation_test.exs -v`
Expected: FAIL — `Operation.Trim.__struct__/0 is undefined` / `function Operation.trim/1 is undefined`.

- [ ] **Step 3: Create the struct**

Create `lib/image_pipe/plan/operation/trim.ex`:

```elixir
defmodule ImagePipe.Plan.Operation.Trim do
  @moduledoc """
  Semantic uniform-border trim operation.

  Detects and removes a uniform-color border. `background: :auto` auto-detects the
  background from the image's top-left pixel (imgproxy "smart"); a `Color` uses an
  explicit background. `equal_hor`/`equal_ver` symmetrize opposite margins to the
  smaller inset. See `docs/imgproxy_support_matrix.md` (pipeline stage 2).
  """

  alias ImagePipe.Plan.Color

  @enforce_keys [:threshold, :background, :equal_hor, :equal_ver]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          threshold: float(),
          background: :auto | Color.t(),
          equal_hor: boolean(),
          equal_ver: boolean()
        }
end
```

- [ ] **Step 4: Add the factory + `semantic?` clause + alias**

In `lib/image_pipe/plan/operation.ex`:

1. Add the alias near the other `alias ImagePipe.Plan.Operation.*` lines (alphabetical, after `Sharpen`/before the closing of the alias block — match the existing ordering):

```elixir
  alias ImagePipe.Plan.Operation.Trim
```

2. Add the factory (place it near `background/1`, after the `background` clauses around line 283):

```elixir
  @trim_keys [:threshold, :background, :equal_hor, :equal_ver]

  @spec trim(keyword()) :: {:ok, Trim.t()} | {:error, error()}
  def trim(opts) when is_list(opts) do
    with :ok <- validate_known_options(:trim, opts, @trim_keys),
         {:ok, threshold} <- trim_threshold(Keyword.get(opts, :threshold)),
         {:ok, background} <- trim_background(Keyword.get(opts, :background, :auto)),
         {:ok, equal_hor} <- trim_flag(Keyword.get(opts, :equal_hor, false)),
         {:ok, equal_ver} <- trim_flag(Keyword.get(opts, :equal_ver, false)) do
      {:ok,
       %Trim{
         threshold: threshold,
         background: background,
         equal_hor: equal_hor,
         equal_ver: equal_ver
       }}
    else
      {:error, {:unknown_operation_options, _operation, _keys} = reason} -> {:error, reason}
      {:error, _reason} -> invalid(:trim, [opts])
    end
  end

  defp trim_threshold(value) when is_number(value), do: {:ok, value * 1.0}
  defp trim_threshold(value), do: {:error, {:invalid_trim_threshold, value}}

  defp trim_background(:auto), do: {:ok, :auto}
  defp trim_background(%Color{} = color) do
    if Color.valid?(color), do: {:ok, color}, else: {:error, {:invalid_trim_background, color}}
  end

  defp trim_background(value), do: {:error, {:invalid_trim_background, value}}

  defp trim_flag(value) when is_boolean(value), do: {:ok, value}
  defp trim_flag(value), do: {:error, {:invalid_trim_flag, value}}
```

3. Add the `semantic?` clause (place it with the other `semantic?` clauses, around line 364, before the `semantic?(_operation)` fallback):

```elixir
  def semantic?(%Trim{} = operation), do: valid_trim?(operation)
```

4. Add the `valid_trim?` helper (place it near `valid_background?`, around line 463):

```elixir
  defp valid_trim?(%Trim{threshold: threshold, background: background} = operation) do
    is_number(threshold) and trim_background_valid?(background) and
      is_boolean(operation.equal_hor) and is_boolean(operation.equal_ver)
  end

  defp trim_background_valid?(:auto), do: true
  defp trim_background_valid?(%Color{} = color), do: Color.valid?(color)
  defp trim_background_valid?(_), do: false
```

> Note: `validate_known_options/3`, `invalid/2`, and `Color.valid?/1` already exist in this module (see `background/1` at line 276 and `valid_background?/1` at line 463). Confirm `@trim_keys` does not collide with another module attribute name.

- [ ] **Step 5: Run it green**

Run: `mise exec -- mix test test/image_pipe/plan/operation_test.exs -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/plan/operation/trim.ex lib/image_pipe/plan/operation.ex test/image_pipe/plan/operation_test.exs
git commit -m "feat(plan): semantic Trim operation + factory (#149)"
```

---

## Task 2: Cache-key data for Trim

**Files:**
- Modify: `lib/image_pipe/plan/key_data.ex`
- Test: `test/image_pipe/plan/operation_key_data_test.exs` (module `ImagePipe.Plan.OperationKeyDataTest` — the `KeyData.data/1` tests live here, NOT in `cache/key_test.exs`, which tests the separate `Cache.Key` layer)

Without a `KeyData.data(%Trim{})` clause, cache-key construction raises `FunctionClauseError` for every trim request (the module has no catch-all). Trim changes output bytes, so it must contribute to the key.

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/plan/operation_key_data_test.exs` (mirror an existing "different X produces different key data" test there), testing `KeyData.data/1` directly:

```elixir
describe "KeyData.data/1 for Trim" do
  alias ImagePipe.Plan.{KeyData, Operation, Color}

  test "different thresholds produce different key data" do
    {:ok, a} = Operation.trim(threshold: 10.0, background: :auto)
    {:ok, b} = Operation.trim(threshold: 20.0, background: :auto)
    assert KeyData.data(a) != KeyData.data(b)
  end

  test "different backgrounds produce different key data; equal trims collide" do
    {:ok, magenta} = Color.rgb(255, 0, 255)
    {:ok, auto} = Operation.trim(threshold: 10.0, background: :auto)
    {:ok, color} = Operation.trim(threshold: 10.0, background: magenta)
    {:ok, auto2} = Operation.trim(threshold: 10.0, background: :auto)

    assert KeyData.data(auto) != KeyData.data(color)
    assert KeyData.data(auto) == KeyData.data(auto2)
  end
end
```

- [ ] **Step 2: Run it red**

Run: `mise exec -- mix test test/image_pipe/plan/operation_key_data_test.exs -v`
Expected: FAIL — `no function clause matching in ImagePipe.Plan.KeyData.data/1`.

- [ ] **Step 3: Implement the clause**

In `lib/image_pipe/plan/key_data.ex`:

1. Add the alias (alphabetical, after `Sharpen` at line 27):

```elixir
  alias ImagePipe.Plan.Operation.Trim
```

2. Add the clause (place it with the other struct clauses, e.g. after `Background` at line 123):

```elixir
  def data(%Trim{} = operation) do
    [
      op: :trim,
      threshold: operation.threshold,
      background: trim_background_data(operation.background),
      equal_hor: operation.equal_hor,
      equal_ver: operation.equal_ver
    ]
  end
```

3. Add the private helper (with the other private helpers, e.g. after `fill_data/1` at line 182):

```elixir
  defp trim_background_data(:auto), do: :auto
  defp trim_background_data(%Color{} = color), do: Color.key_data(color)
```

- [ ] **Step 4: Run it green**

Run: `mise exec -- mix test test/image_pipe/plan/operation_key_data_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plan/key_data.ex test/image_pipe/plan/operation_key_data_test.exs
git commit -m "feat(cache): Trim cache-key data (#149)"
```

---

## Task 3: Executable `Transform.Operation.Trim` (replicates `vips_trim`)

**Files:**
- Create: `lib/image_pipe/transform/operation/trim.ex`
- Test: `test/image_pipe/transform/operation/trim_test.exs` (create)

This op is the heart of the feature. It must replicate `vips/vips.c:875` exactly. Reviewer-verified library facts: `Image.flatten/2` uses the `:background_color` key (NOT `:background`); `Plan.Color.channels` is an `{r,g,b}` **tuple** (convert with `Tuple.to_list/1`); the **raw** `Vix.Vips.Operation.find_trim/2` returns `{:ok, {left, top, width, height}}` and signals nothing-to-trim as `{:ok, {l, t, 0, 0}}` (NOT a `:nothing_to_trim` error — that is the higher-level `Image.find_trim` wrapper); any `{:error, _}` from the raw op is a genuine failure and must propagate.

- [ ] **Step 1: Write the failing tests**

Create `test/image_pipe/transform/operation/trim_test.exs`. Build fixtures with `Vix.Vips.Operation` so the test is self-contained (a bordered image = a small inner block embedded on a solid background). Helper builds an image with a uniform border around a distinct center:

```elixir
defmodule ImagePipe.Transform.Operation.TrimTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Color
  alias ImagePipe.Transform.Operation.Trim
  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation

  # Builds a `width`x`height` image filled with `bg` (an [r,g,b] list) with an
  # inner `inner_w`x`inner_h` block of `fg` at (left, top).
  defp bordered(width, height, bg, fg, left, top, inner_w, inner_h) do
    {:ok, canvas} = Operation.black(width, height, bands: 3)
    {:ok, canvas} = Operation.linear(canvas, [1.0, 1.0, 1.0], bg)
    {:ok, block} = Operation.black(inner_w, inner_h, bands: 3)
    {:ok, block} = Operation.linear(block, [1.0, 1.0, 1.0], fg)
    {:ok, composed} = Operation.insert(canvas, block, left, top)
    composed
  end

  defp state(image), do: %State{image: image} |> Map.put(:materialized?, true)

  test "requires materialization" do
    assert Trim.requires_materialization?(%Trim{
             threshold: 10.0,
             background: :auto,
             equal_hor: false,
             equal_ver: false
           })
  end

  test "smart (:auto) trims a uniform border to the inner block" do
    img = bordered(40, 40, [0, 0, 0], [255, 255, 255], 10, 8, 20, 24)
    op = %Trim{threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false}

    assert {:ok, %State{image: out}} = Trim.execute(op, state(img))
    assert Image.width(out) == 20
    assert Image.height(out) == 24
  end

  test "explicit color background trims" do
    {:ok, black} = Color.rgb(0, 0, 0)
    img = bordered(40, 40, [0, 0, 0], [255, 255, 255], 5, 5, 30, 30)
    op = %Trim{threshold: 10.0, background: black, equal_hor: false, equal_ver: false}

    assert {:ok, %State{image: out}} = Trim.execute(op, state(img))
    assert Image.width(out) == 30
    assert Image.height(out) == 30
  end

  test "uniform image is a no-op (returned unchanged), never an error" do
    {:ok, img} = Operation.black(20, 20, bands: 3)
    op = %Trim{threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false}

    assert {:ok, %State{image: out}} = Trim.execute(op, state(img))
    assert Image.width(out) == 20
    assert Image.height(out) == 20
  end

  test "equal_hor symmetrizes to the smaller horizontal margin" do
    # inner block flush-left-ish: left margin 4, right margin 16 -> equal_hor keeps 4 each
    img = bordered(40, 40, [0, 0, 0], [255, 255, 255], 4, 4, 20, 32)
    plain = %Trim{threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false}
    equal = %Trim{threshold: 10.0, background: :auto, equal_hor: true, equal_ver: false}

    assert {:ok, %State{image: plain_out}} = Trim.execute(plain, state(img))
    assert {:ok, %State{image: equal_out}} = Trim.execute(equal, state(img))
    # equal_hor keeps a wider box (margins reduced to the smaller side)
    assert Image.width(equal_out) > Image.width(plain_out)
  end

  test "alpha source detects against a magenta flatten (border distinct from magenta)" do
    # A real RGBA image (interpretation sRGB so has_alpha?/1 is true): a fully
    # transparent border with an OPAQUE green center. The magenta flatten turns the
    # transparent border magenta; the opaque green center differs -> trims to it.
    # If the border were flattened onto BLACK (the `:background` bug), green-vs-black
    # still differs and would also trim, so to actually catch the wrong-key bug the
    # CENTER is chosen green (distinct from BOTH magenta and black) and the test
    # additionally asserts the op did not raise — the dimension assertion is the
    # primary signal that the alpha path ran end to end.
    transparent = [0, 0, 0, 0]
    green = [10, 200, 10, 255]

    {:ok, canvas} = Vix.Vips.Image.build_image(40, 40, transparent, interpretation: :VIPS_INTERPRETATION_sRGB)
    {:ok, center} = Vix.Vips.Image.build_image(16, 16, green, interpretation: :VIPS_INTERPRETATION_sRGB)
    assert Image.has_alpha?(canvas)
    {:ok, composed} = Operation.insert(canvas, center, 12, 12)

    op = %Trim{threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false}

    assert {:ok, %State{image: out}} = Trim.execute(op, state(composed))
    assert Image.width(out) == 16
    assert Image.height(out) == 16
  end
end
```

> Reviewer-verified: `Operation.black(bands: 4)` / `bandjoin` produce `:VIPS_INTERPRETATION_MULTIBAND` images for which `Image.has_alpha?/1` is **false** — the alpha path would silently never run. Use `Vix.Vips.Image.build_image(w, h, [r,g,b,a], interpretation: :VIPS_INTERPRETATION_sRGB)` (probe-confirmed `has_alpha? == true`). The `assert Image.has_alpha?(canvas)` guard fails loudly if the build doesn't yield an alpha band. Confirm `build_image/3`'s arg shape with one `mise exec -- iex -S mix` probe if it errors.

- [ ] **Step 2: Run it red**

Run: `mise exec -- mix test test/image_pipe/transform/operation/trim_test.exs -v`
Expected: FAIL — `Trim.__struct__/0` / `Trim.execute/2` undefined.

- [ ] **Step 3: Implement the executable op**

Create `lib/image_pipe/transform/operation/trim.ex`:

```elixir
defmodule ImagePipe.Transform.Operation.Trim do
  @moduledoc """
  Executable uniform-border trim. Replicates imgproxy `vips_trim`
  (`vips/vips.c`): prepare a detection copy (sRGB convert; magenta-flatten alpha),
  resolve the background (top-left pixel for `:auto`, else the explicit color),
  `find_trim`, symmetrize via `equal_hor`/`equal_ver`, return unchanged on a
  degenerate box, and extract from the original image.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State, only: [set_image: 2]

  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation

  # Integers, NOT floats: Image.flatten treats a float list as sRGB 0.0..1.0 and
  # rejects 255.0 (Color.InvalidComponentError). Integer 0..255 is accepted.
  @magenta [255, 0, 255]

  @enforce_keys [:threshold, :background, :equal_hor, :equal_ver]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          threshold: float(),
          background: :auto | ImagePipe.Plan.Color.t(),
          equal_hor: boolean(),
          equal_ver: boolean()
        }

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :trim

  @impl ImagePipe.Transform
  def requires_materialization?(%__MODULE__{}), do: true

  @impl ImagePipe.Transform
  def execute(%__MODULE__{} = op, %State{} = state) do
    original = state.image
    orig_w = Image.width(original)
    orig_h = Image.height(original)

    with {:ok, prepared} <- prepare(original),
         {:ok, background} <- background_list(op.background, prepared),
         {:ok, {left, top, width, height}} <-
           Operation.find_trim(prepared, background: background, threshold: op.threshold) do
      {left, width} = equalize(op.equal_hor, left, width, orig_w)
      {top, height} = equalize(op.equal_ver, top, height, orig_h)

      if width == 0 or height == 0 do
        {:ok, state}
      else
        case Image.crop(original, left, top, width, height) do
          {:ok, cropped} -> {:ok, set_image(state, cropped)}
          {:error, error} -> {:error, {__MODULE__, error}}
        end
      end
    else
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  # Detection copy: convert to sRGB if needed, then flatten alpha onto magenta.
  defp prepare(image) do
    with {:ok, srgb} <- to_srgb(image) do
      flatten_alpha(srgb)
    end
  end

  defp to_srgb(image) do
    case Vix.Vips.Image.interpretation(image) do
      :VIPS_INTERPRETATION_sRGB -> {:ok, image}
      _ -> Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB)
    end
  end

  defp flatten_alpha(image) do
    if Image.has_alpha?(image) do
      Image.flatten(image, background_color: @magenta)
    else
      {:ok, image}
    end
  end

  # Background as a band-matched list. `:auto` = the top-left pixel of the prepared
  # (3-band sRGB) image; an explicit Color = its [r,g,b] channels.
  defp background_list(:auto, prepared) do
    case Image.get_pixel(prepared, 0, 0) do
      {:ok, pixel} -> {:ok, pixel}
      {:error, error} -> {:error, error}
    end
  end

  defp background_list(%ImagePipe.Plan.Color{channels: channels}, _prepared) do
    {:ok, Tuple.to_list(channels)}
  end

  # equal_hor/equal_ver: grow the box on the more-trimmed side so opposite margins
  # equal the smaller inset. Mirrors imgproxy vips.c lines 927-949. `near` is the
  # near-edge margin (left/top), `extent` the box size, `total` the original axis.
  defp equalize(false, near, extent, _total), do: {near, extent}

  defp equalize(true, near, extent, total) do
    far = total - near - extent
    diff = far - near

    cond do
      diff > 0 -> {near, extent + diff}
      diff < 0 -> {far, extent - diff}
      true -> {near, extent}
    end
  end
end
```

> Reviewer-verified against the pinned fork (do not re-debug these): `Vix.Vips.Image.interpretation/1` returns a **bare atom** (the `case` shape is correct); `Vix.Vips.Operation.colourspace/2` → `{:ok, image}`; `Image.has_alpha?/1`; `Image.flatten/2` uses `:background_color` (integer list); `Image.get_pixel/3` → `{:ok, [r,g,b]}`; `Vix.Vips.Operation.find_trim/2` takes `background:`/`threshold:` and returns `{:ok, {l,t,w,h}}` (uniform → `{:ok, {_,_,0,0}}`, a 1×1 image → `{:error, "...window too large"}`); `Image.crop/5`. `Image` resolves as the hex lib's top module with no alias needed (mirrors `crop.ex`); `set_image/2` is imported from `ImagePipe.Transform.State`. **Do not chase the sRGB-skip fast path for synthetic test fixtures:** `black`/`linear`/`insert` images report `:VIPS_INTERPRETATION_MULTIBAND` and fall through to the `colourspace` branch (which also keeps MULTIBAND) — find_trim still succeeds, and real JPEG/PNG sources report sRGB properly. The skip is for real sources, not the fixtures.

- [ ] **Step 4: Run it green**

Run: `mise exec -- mix test test/image_pipe/transform/operation/trim_test.exs -v`
Expected: PASS. If a fixture builder errors on Vix arity, fix the fixture (not the op) and re-run.

- [ ] **Step 5: Add the failure-propagation + degenerate×equal tests**

Append to the test file:

```elixir
  test "a find_trim failure (sub-window image) propagates as an error, not a no-op" do
    {:ok, tiny} = Operation.black(1, 1, bands: 3)
    op = %Trim{threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false}
    assert {:error, {Trim, _}} = Trim.execute(op, state(tiny))
  end

  test "uniform + equal_hor only stays a no-op (vertical axis still 0)" do
    {:ok, img} = Operation.black(20, 20, bands: 3)
    op = %Trim{threshold: 10.0, background: :auto, equal_hor: true, equal_ver: false}
    assert {:ok, %State{image: out}} = Trim.execute(op, state(img))
    assert Image.width(out) == 20 and Image.height(out) == 20
  end
```

> If a 1×1 image does not error on the pinned libvips (find_trim window depends on build), use the smallest size that does (e.g. 2×2 or 3×3) — confirm with one `iex` probe. The contract under test is "`{:error,_}` from find_trim is not swallowed."

- [ ] **Step 6: Run + commit**

Run: `mise exec -- mix test test/image_pipe/transform/operation/trim_test.exs -v`
Expected: PASS.

```bash
git add lib/image_pipe/transform/operation/trim.ex test/image_pipe/transform/operation/trim_test.exs
git commit -m "feat(transform): executable Trim op replicating vips_trim (#149)"
```

---

## Task 4: PlanExecutor translation `PlanTrim → Trim`

**Files:**
- Modify: `lib/image_pipe/transform/plan_executor.ex`
- Test: covered end-to-end by Task 7 wire tests; add a focused translation test here if `plan_executor` has a unit test file (`ls test/image_pipe/transform/`).

- [ ] **Step 1: Add the aliases**

In `lib/image_pipe/transform/plan_executor.ex`:
- With the Plan aliases (after `Sharpen, as: PlanSharpen` at line 31):

```elixir
  alias ImagePipe.Plan.Operation.Trim, as: PlanTrim
```

- With the Transform aliases (after `Sharpen` at line 49):

```elixir
  alias ImagePipe.Transform.Operation.Trim
```

- [ ] **Step 2: Add the translation clause**

Add a clause alongside the other simple `executable_operations/3` clauses (e.g. near `PlanBlur` at the line shown by `grep -n "%PlanBlur" lib/image_pipe/transform/plan_executor.ex`):

```elixir
  defp executable_operations(%PlanTrim{} = operation, %State{}, _context),
    do: [
      %Trim{
        threshold: operation.threshold,
        background: operation.background,
        equal_hor: operation.equal_hor,
        equal_ver: operation.equal_ver
      }
    ]
```

- [ ] **Step 3: Verify compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/transform/plan_executor.ex
git commit -m "feat(transform): translate PlanTrim to executable Trim (#149)"
```

---

## Task 5: Decode planner — Trim blocks shrink-on-load (first pipeline only)

**Files:**
- Modify: `lib/image_pipe/transform/decode_planner.ex`
- Test: `test/image_pipe/decode_planner_test.exs` (find with `ls test/image_pipe/transform/`)

`DecodePlanner` is fed only `first_pipeline_operations` (see `request/processor.ex`), so blocking shrink when the chain contains a `Trim` disables shrink-on-load iff trim is in the first pipeline — matching imgproxy.

- [ ] **Step 1: Write the failing test**

Add to `decode_planner_test.exs` (mirror its existing `open_options` cases — check how it constructs `chain`; it uses `Plan.Operation.*` structs). Example:

```elixir
test "a chain containing Trim blocks shrink-on-load" do
  {:ok, trim} = ImagePipe.Plan.Operation.trim(threshold: 10.0, background: :auto)
  {:ok, resize} = ImagePipe.Plan.Operation.resize(:fit, {:px, 100}, {:px, 100})
  chain = [trim, resize]

  opts = ImagePipe.Transform.DecodePlanner.open_options(chain, :jpeg, {800, 800}, false, false)

  refute Keyword.has_key?(opts, :shrink)
  refute Keyword.has_key?(opts, :scale)
end

test "the same resize without Trim does shrink-on-load" do
  {:ok, resize} = ImagePipe.Plan.Operation.resize(:fit, {:px, 100}, {:px, 100})
  opts = ImagePipe.Transform.DecodePlanner.open_options([resize], :jpeg, {800, 800}, false, false)
  assert Keyword.get(opts, :shrink) >= 2
end
```

> Confirm `open_options/5` arity and the exact tagged-dimension shape (`{:px, n}`) against the existing tests in that file before running — adjust the resize construction to match how sibling tests build it.

- [ ] **Step 2: Run it red**

Run: `mise exec -- mix test test/image_pipe/decode_planner_test.exs -v`
Expected: FAIL — the Trim case still emits a `shrink`.

- [ ] **Step 3: Implement the block**

In `lib/image_pipe/transform/decode_planner.ex`:

1. Add the alias with the other `Plan.Operation` aliases (around line 16-19):

```elixir
  alias ImagePipe.Plan.Operation.Trim, as: PlanTrim
```

2. Short-circuit `compute_load_shrink/3` (at line 120). Change:

```elixir
  defp compute_load_shrink(chain, src_w, src_h) do
    {crop_w, crop_h} = crop_extent_before_resize(chain, src_w, src_h)

    case Enum.find(chain, &match?(%PlanResize{}, &1)) do
      nil -> 1.0
      resize -> resize_load_shrink(resize, crop_w, crop_h)
    end
  end
```

to:

```elixir
  defp compute_load_shrink(chain, src_w, src_h) do
    if Enum.any?(chain, &match?(%PlanTrim{}, &1)) do
      # Trim redefines source dimensions (imgproxy nils ImgData), so any shrink
      # sized against the original would be wrong. Forgo shrink-on-load — only
      # affects the first pipeline, matching imgproxy (trim disables scaleOnLoad).
      1.0
    else
      {crop_w, crop_h} = crop_extent_before_resize(chain, src_w, src_h)

      case Enum.find(chain, &match?(%PlanResize{}, &1)) do
        nil -> 1.0
        resize -> resize_load_shrink(resize, crop_w, crop_h)
      end
    end
  end
```

- [ ] **Step 4: Run it green**

Run: `mise exec -- mix test test/image_pipe/decode_planner_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/decode_planner.ex test/image_pipe/decode_planner_test.exs
git commit -m "feat(transform): Trim blocks shrink-on-load in the first pipeline (#149)"
```

---

## Task 6: imgproxy parser — `trim`/`t` option

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/pipeline_request.ex`
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex`
- Modify: `lib/image_pipe/parser/imgproxy/options.ex`
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex`
- Test: `test/parser/imgproxy/option_grammar_test.exs + plan_builder_test.exs + options_test.exs` (under `test/parser/imgproxy/` — NOT `test/image_pipe/parser/`)

### 6a: `PipelineRequest` field

- [ ] **Step 1:** In `lib/image_pipe/parser/imgproxy/pipeline_request.ex`, add `trim: nil,` to the `defstruct` (e.g. after `crop_aspect_ratio_enlarge: false,` at line 88). No test needed for a struct default; covered downstream.

### 6b: Grammar parse

- [ ] **Step 2: Write the failing grammar test**

Add to `test/parser/imgproxy/option_grammar_test.exs`. Mirror the existing `parse_special_option` tests (e.g. for `padding`/`monochrome`):

```elixir
describe "trim" do
  test "parses threshold only (smart background)" do
    assert {:ok, {:pipeline, [trim: trim]}} = OptionGrammar.parse("trim:15")
    assert trim[:threshold] == 15.0
    assert trim[:background] == :auto
    assert trim[:equal_hor] == false
    assert trim[:equal_ver] == false
  end

  test "alias t with color and equal flags" do
    assert {:ok, {:pipeline, [trim: trim]}} = OptionGrammar.parse("t:10:ff00ff:1:1")
    assert trim[:threshold] == 10.0
    assert %ImagePipe.Plan.Color{} = trim[:background]
    assert trim[:equal_hor] == true
    assert trim[:equal_ver] == true
  end

  test "empty threshold disables trim (no assignment)" do
    assert {:ok, {:pipeline, []}} = OptionGrammar.parse("trim:")
  end

  test "rejects more than 4 args" do
    assert {:error, _} = OptionGrammar.parse("trim:10:ff00ff:1:1:0")
  end

  test "rejects a bad threshold" do
    assert {:error, _} = OptionGrammar.parse("trim:nope")
  end

  test "rejects a bad boolean (stricter than imgproxy, like enlarge)" do
    assert {:error, _} = OptionGrammar.parse("trim:10::x")
  end
end
```

- [ ] **Step 3: Run it red**

Run: `mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs -v`
Expected: FAIL — `{:error, {:unknown_option, "trim"}}`.

- [ ] **Step 4: Implement the grammar**

In `lib/image_pipe/parser/imgproxy/option_grammar.ex`:

1. Add the dispatch clause with the other `parse_special_option` clauses (after the `duotone` clause around line 513, before the `{:unknown_option, name}` fallback at line 517):

```elixir
  defp parse_special_option(name, args, segment) when name in ["trim", "t"] do
    parse_trim(args, segment)
  end
```

2. Add the `parse_trim` implementation (near the other `parse_*` helpers, e.g. after `parse_duotone`):

```elixir
  # trim:%threshold:%color:%equal_hor:%equal_ver — enabled iff threshold is set.
  # Returns a BARE keyword `{:ok, [trim: …]}` (or `{:ok, []}` when disabled): the
  # caller `parse_pipeline_option/_` adds the `{:pipeline, …}` wrapper, exactly like
  # `parse_padding`/`parse_duotone`. Do NOT wrap it here — double-wrapping
  # (`{:pipeline, {:pipeline, …}}`) breaks the apply step and the grammar test.
  defp parse_trim([threshold | _rest], _segment) when threshold == "", do: {:ok, []}
  defp parse_trim([], _segment), do: {:ok, []}

  defp parse_trim(args, _segment) when length(args) <= 4 do
    [threshold | rest] = args

    with {:ok, threshold} <- parse_float(threshold),
         {:ok, background} <- parse_trim_color(Enum.at(rest, 0)),
         {:ok, equal_hor} <- parse_trim_flag(Enum.at(rest, 1)),
         {:ok, equal_ver} <- parse_trim_flag(Enum.at(rest, 2)) do
      {:ok,
       [
         trim: [
           threshold: threshold,
           background: background,
           equal_hor: equal_hor,
           equal_ver: equal_ver
         ]
       ]}
    end
  end

  defp parse_trim(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_trim_color(nil), do: {:ok, :auto}
  defp parse_trim_color(""), do: {:ok, :auto}

  defp parse_trim_color(hex) do
    case Color.rgb_hex(hex) do
      {:ok, color} -> {:ok, color}
      {:error, {:invalid_color, _}} -> {:error, {:invalid_trim_color, hex}}
    end
  end

  defp parse_trim_flag(nil), do: {:ok, false}
  defp parse_trim_flag(""), do: {:ok, false}
  defp parse_trim_flag(value), do: parse_boolean(value)
```

> `parse_float/1` (line 1053), `parse_boolean/1` (line 418), and `Color.rgb_hex/1` already exist. Reviewer-verified: a multi-arg `trim:…` segment routes through `parse/1 → parse_pipeline_option → parse_special_option/3` automatically once the dispatch clause above is added — **do not** add `"trim"`/`"t"` to `@special_specs` (that table is for fixed-arity declarative options via `interpret_special`, the wrong path for trim's optional-arity sub-grammar).

- [ ] **Step 5: Run it green**

Run: `mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs -v`
Expected: PASS.

### 6c: Apply assignment to the pipeline

- [ ] **Step 6:** In `lib/image_pipe/parser/imgproxy/options.ex`, add a clause to the `update_current_pipeline/2` reduce (after the `:background_alpha` clause at line 225-226, before the `@effect_fields` clause):

```elixir
        {:trim, trim_assignments}, pipeline ->
          %{pipeline | trim: trim_assignments}
```

> This stores the parsed keyword on the field; the plan builder (6d) constructs the semantic op from it. No new `apply_*` helper needed.

### 6d: plan_builder emits the semantic op first

- [ ] **Step 7: Write the failing plan-builder test**

Add to `test/parser/imgproxy/plan_builder_test.exs`. Assert order and translation:

```elixir
test "trim is emitted first in geometry order" do
  {:ok, plan} = ImagePipe.Parser.Imgproxy.parse("trim:10/rs:fit:100:100", imgproxy: [])
  ops = hd(plan.pipelines).operations
  assert [%ImagePipe.Plan.Operation.Trim{threshold: 10.0} | _rest] = ops
end
```

> Confirm `Parser.Imgproxy.parse/2`'s return shape and how to reach the first pipeline's operations from sibling tests (the pipeline field/struct name) and adjust the access. If `parse/2` needs validated imgproxy options, pass `imgproxy: ImagePipe.Parser.Imgproxy.validate_options!([])`.

- [ ] **Step 8: Run it red**

Run: `mise exec -- mix test test/parser/imgproxy/plan_builder_test.exs -v`
Expected: FAIL — no Trim op emitted.

- [ ] **Step 9: Implement in `plan_builder.ex`**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`:

1. In `plan_geometry/1` (line 218), add `trim_operations` first:

```elixir
  defp plan_geometry(%PipelineRequest{} = request) do
    with {:ok, trim_operations} <- trim_operations(request),
         {:ok, orientation_operations} <- orientation_operations(request),
         {:ok, crop_operations} <- crop_operations(request),
         {:ok, resize_operations} <- resize_operations(request),
         {:ok, color_profile_operations} <- color_profile_operations(request),
         {:ok, effect_operations} <- effect_operations(request),
         {:ok, canvas_operations} <- canvas_operations(request),
         {:ok, padding_operations} <- padding_operations(request),
         {:ok, background_operations} <- background_operations(request) do
      {:ok,
       trim_operations ++
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

2. Add the `trim_operations/1` helper (near `background_operations/1` at line 452):

```elixir
  defp trim_operations(%PipelineRequest{trim: nil}), do: {:ok, []}

  defp trim_operations(%PipelineRequest{trim: trim}) do
    with {:ok, operation} <- Operation.trim(trim) do
      {:ok, [operation]}
    end
  end
```

> `Operation` is already aliased in `plan_builder.ex` (it calls `Operation.crop`, `Operation.background`, etc.). The parser stored `trim` as the keyword `[threshold:, background:, equal_hor:, equal_ver:]`, which `Operation.trim/1` accepts directly.

> **Known limitation (intentional, matches existing behavior):** `plan_geometry/1` has early-return clauses (plan_builder.ex:201-216) for `:fill`/`:fill_down`/`:auto` resizing types with missing dimensions that return `missing_dimensions` before reaching the general clause — so `trim:10` on a dimensionless `:fill` request errors out and trim is not applied. This is consistent with how orientation/crop are also skipped on those paths (they error anyway). We do **not** add trim to those early clauses.

- [ ] **Step 9b: Pin the known limitation with a test**

Add to `test/parser/imgproxy/plan_builder_test.exs`:

```elixir
test "trim on a dimensionless :fill request errors as missing_dimensions, not a trim crash" do
  assert {:error, {:missing_dimensions, _}} =
           ImagePipe.Parser.Imgproxy.parse("trim:10/rt:fill", imgproxy: [])
           |> then(fn {:ok, _} = ok -> ok; err -> err end)
end
```

> Confirm the exact error tag/shape `rt:fill` with no width/height produces by reading the `:fill` early-return clause at plan_builder.ex:201-204 and matching its return; adjust the assertion to that tag. The point is that trim does not change this path's behavior.

- [ ] **Step 10: Run it green + commit**

Run: `mise exec -- mix test test/parser/imgproxy/ -v`
Expected: PASS.

```bash
git add lib/image_pipe/parser/imgproxy/ test/parser/imgproxy/
git commit -m "feat(parser): imgproxy trim/t option -> semantic Trim (#149)"
```

---

## Task 7: Wire-level conformance tests

**Files:**
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs`
- Test fixtures: reuse the test's existing fixture helpers (inspect the file first for how it builds/loads source images and makes `ImagePipe.call/2` requests).

- [ ] **Step 1: Add origin fixtures + opts**

The harness serves a source via a custom origin Plug mapped through `sources: [path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: <Module>]}]` and requests it with `call_imgproxy("/_/...opts.../plain/images/<name>.png", opts)`. `dimensions(conn)` decodes the body and returns `{w, h}` (both helpers already exist — `EffectOriginImage` at line 221, `effect_origin_opts/0` at line 2799, `call_imgproxy/3` at line 2832, `dimensions/1` at line 2853).

Add two origin modules next to `EffectOriginImage` (mirror its `call/2` shape exactly — `Image.new!/2` + `Image.Draw.rect!/6` + `Image.write!(:memory, suffix: ".png")`):

```elixir
  defmodule TrimOriginImage do
    @moduledoc false
    # 64x64 black border with a white 40x44 inner block at (12, 10).
    def call(conn, _opts) do
      body =
        64
        |> Image.new!(64, color: :black)
        |> Image.Draw.rect!(12, 10, 40, 44, color: :white)
        |> Image.write!(:memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule UniformOriginImage do
    @moduledoc false
    # Solid 64x64 black — nothing to trim.
    def call(conn, _opts) do
      body = Image.new!(64, 64, color: :black) |> Image.write!(:memory, suffix: ".png")
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, body)
    end
  end
```

And the matching opts (mirror `effect_origin_opts/0` at line 2799):

```elixir
  defp trim_origin_opts, do: origin_opts(TrimOriginImage)
  defp uniform_origin_opts, do: origin_opts(UniformOriginImage)

  defp origin_opts(plug) do
    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: plug]}
      ]
    ]
  end
```

> If `Image.new!/2` color arg or `Image.Draw.rect!/6` arity differs, copy the exact call shape from `EffectOriginImage` (lines 221-238) — it is the verified template.

- [ ] **Step 2: Add trim wire tests**

```elixir
describe "trim (wire)" do
  test "trims a uniform border to the inner block, no resize" do
    conn = call_imgproxy("/_/trim:10/f:png/plain/images/trim.png", trim_origin_opts())
    assert conn.status == 200
    assert dimensions(conn) == {40, 44}
  end

  test "uniform image returns unchanged (no-op), no geometry options" do
    conn = call_imgproxy("/_/trim:10/f:png/plain/images/uniform.png", uniform_origin_opts())
    assert conn.status == 200
    assert dimensions(conn) == {64, 64}
  end
end
```

> Keep this representative, not exhaustive — grammar edge cases live in Task 6's parser tests (per the test guidelines). The black border vs white inner block gives the threshold a wide margin, so the exact threshold value is not brittle.

- [ ] **Step 3: Run + commit**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs -v`
Expected: PASS.

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(imgproxy): wire conformance for trim (#149)"
```

---

## Task 8: Boundary exports + architecture test

**Files:**
- Modify: `lib/image_pipe/plan.ex`, `lib/image_pipe/transform.ex`
- Modify: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Run the architecture test to see it fail**

After Tasks 1 & 3 the new modules exist but are not exported. Run:
`mise exec -- mix test test/image_pipe/architecture_boundary_test.exs -v`
Expected: it may already pass if exports aren't asserted exactly — but the Plan export list is an exact-match (`==`). Confirm by reading `test/image_pipe/architecture_boundary_test.exs` around the `assert_boundary_exports(plan, [...])` and `assert_boundary_exports_include(transform, [...])` assertions.

- [ ] **Step 2: Add the exports**

- In `lib/image_pipe/plan.ex`, add `ImagePipe.Plan.Operation.Trim` to the `exports:` list (keep alphabetical with the other `Operation.*` exports).
- In `lib/image_pipe/transform.ex`, add `ImagePipe.Transform.Operation.Trim` to its `exports:` list.
- In `test/image_pipe/architecture_boundary_test.exs`, add `ImagePipe.Plan.Operation.Trim` to the exact-match plan export list, and `ImagePipe.Transform.Operation.Trim` to the transform export list (matching the existing entries' formatting).

- [ ] **Step 3: Run it green**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs -v`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/plan.ex lib/image_pipe/transform.ex test/image_pipe/architecture_boundary_test.exs
git commit -m "chore(boundary): export Trim plan + transform ops (#149)"
```

---

## Task 9: Demo UI controls

**Files:**
- Modify: `demo/` Svelte app (controls + imgproxy URL state). Inspect first: find where existing options like `padding`/`blur` are wired (`grep -rn "padding\|blur" demo/src`).

- [ ] **Step 1: Inspect the demo's option wiring**

Run: `grep -rln "blur\|padding\|imgproxy" demo/src | head` and read the control + URL-builder modules an existing multi-arg option uses.

- [ ] **Step 2: Add trim controls**

Following the existing pattern for a multi-field option, add:
- an enable toggle (presence of threshold),
- a threshold number input,
- a background mode select (auto vs color) with a color picker for the color case,
- equal-hor and equal-ver checkboxes,

and have the URL builder emit `trim:<threshold>[:<hex>][:<eh>][:<ev>]` (omit trailing empty args; emit nothing when disabled).

- [ ] **Step 3: Verify the demo builds**

Run: `mise run precommit:demo`
Expected: the Elixir gate + `mix demo.verify` pass.

- [ ] **Step 4: Commit**

```bash
git add demo/
git commit -m "feat(demo): trim controls + URL state (#149)"
```

---

## Task 10: Conformance doc (3 axes)

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Stage axis** — flip pipeline stage 2 `trim` from ⭕ to ✅. Update the mermaid: change `A2["2 trim ⭕"]` to `A2["2 trim ✅"]` and move `A2` from the `none` class to the `chain` class (the `class A4,A5,...` line). Update the stage-2 row in the "Main pipeline" table: "Realized in" → `lib/image_pipe/transform/operation/trim.ex`, Status ⭕→✅, Notes describing the replication and the first-pipeline shrink-on-load interaction.

- [ ] **Step 2: Surface axis** — in "Resize, geometry, and orientation", change the `trim` / `t` row from `Missing` to `Supported`, with notes: 4-arg grammar, "empty threshold disables", smart vs explicit color, equal_hor/ver.

- [ ] **Step 3: Behavioral axis** — add the Diverges notes from the spec, naming the concrete user-visible effect for each:
  - **Detection colorspace (folded into #124):** for a source with a non-sRGB embedded ICC profile (wide-gamut), imgproxy detects the border in processing space (it imports the profile before trim); ImagePipe detects in the source-profile space → **different trim boxes on wide-gamut sources**. Resolved when #124 lands.
  - **smart bg = the top-left pixel** (`getpoint(0,0)`), not a border median.
  - **bad-bool strictness** (codebase-wide): invalid `equal_hor`/`equal_ver` error in ImagePipe vs coerce-to-false in imgproxy — cross-link [#173].
  - **sRGB-skip uses stored header interpretation**, not imgproxy's `guess_interpretation` — at most an extra idempotent sRGB round-trip, no dimension effect.

- [ ] **Step 4: Commit**

```bash
git add docs/imgproxy_support_matrix.md
git commit -m "docs(imgproxy): trim conformance — stage 2 ✅, surface + divergences (#149)"
```

---

## Task 11: Full gate + close-out

- [ ] **Step 1: Run the full precommit gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all pass. Fix anything red (format with `mise exec -- mix format`).

- [ ] **Step 2: Run the demo gate (touched demo)**

Run: `mise run precommit:demo`
Expected: PASS.

- [ ] **Step 3: Final commit if the gate produced formatting changes**

```bash
git add -A
git commit -m "chore: format + gate fixes for trim (#149)"
```

---

## Self-review notes (author)

- **Spec coverage:** Plan op (T1), key data (T2), executable op replicating `vips_trim` incl. magenta-flatten/`:background_color`, tuple→list bg, raw-find_trim no-op/error contract, equal-math, 422 error class (T3), translation (T4), shrink-block first-pipeline-only (T5), parser 4-arg grammar + empty-disables + bool strictness + first-in-order (T6), wire conformance (T7), boundary exports (T8), demo (T9), conformance doc 3 axes (T10), gate (T11). All spec sections map to a task.
- **Divergences:** detection colorspace folded into #124 (doc only, no code) — Task 10 step 3; bad-bool strictness uses existing `parse_boolean` — Task 6.
- **Type consistency:** `%Trim{threshold, background, equal_hor, equal_ver}` identical across plan op, executable op, key data, parser keyword, and translation. `background` is `:auto | %Color{}` everywhere; executable op converts `%Color{}.channels` tuple → list only at the libvips boundary.
- **Arity caveats:** Task 3 and Task 7 call out verifying Vix/Image arities with one `iex` probe before debugging — the pinned `vix` is a git fork (`mix.exs:110`), so do not assume hexdocs arities blindly.
