# TwicPics Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `ImagePipe.Parser.TwicPics` compatibility parser (core geometry + output) that translates `?twic=v1/…` URLs into a product-neutral `ImagePipe.Plan`, with full running-dimension fidelity for relative units.

**Architecture:** A new parser boundary mirrors `ImagePipe.Parser.Imgproxy`: it parses the request path into a `Source.Path`, folds the ordered `twic` chain into ordered `Plan.Operation.*` via constructors, and reuses the shared source/cache/output/runtime. A small, additive, multi-site core change lets `Plan.Operation.Resize` carry `{:percent, n}` / `{:scale, f}` dimensions that resolve against the running image at execute time.

**Tech Stack:** Elixir, Plug, Vix/libvips (`Image`), NimbleOptions, ExUnit, Boundary, StreamData.

**Spec:** `docs/superpowers/specs/2026-05-31-twicpics-parser-design.md`. **Support matrix:** `docs/twicpics_support_matrix.md`.

**Scope notes (refinements made during planning, reflected in the spec):**
- **v1 focus = the 8 anchors only.** Coordinate focus (px/percent/scale) is deferred — the Plan focal guide is a 0..1 ratio and pixel-coordinate focus needs runtime-resolved focal points (a separate core change). Crop `@coords` are unaffected.
- **The demo TwicPics mode is a separate follow-on plan**, not part of this one. The demo has no parser-mode abstraction; adding one is an independent TS/Svelte subsystem.

**Conventions for every task:** run Elixir tooling through `mise exec -- …`. Run a single test file with `mise exec -- mix test path:line`. Before each commit the focused tests for that task must pass.

---

## Phase 1 — Core: relative resize dimensions

This phase is independent of TwicPics and must land first. Existing imgproxy callers construct only `:auto` / `{:px, n}` resize dims and are unaffected — every change is additive.

### Task 1.1: Widen the semantic Resize dimension + validate relative units

**Files:**
- Modify: `lib/image_pipe/plan/operation/resize.ex:18`
- Modify: `lib/image_pipe/plan/operation.ex:493-498`
- Test: `test/image_pipe/plan/operation_test.exs` (create if absent)

- [ ] **Step 1: Write the failing test**

Add to `test/image_pipe/plan/operation_test.exs`:

```elixir
defmodule ImagePipe.Plan.OperationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Resize

  describe "resize/4 relative dimensions" do
    test "accepts percent and scale width/height" do
      assert {:ok, %Resize{width: {:percent, 50}, height: :auto}} =
               Operation.resize(:fit, {:percent, 50}, :auto)

      assert {:ok, %Resize{width: {:scale, 0.5}, height: {:px, 100}}} =
               Operation.resize(:cover, {:scale, 0.5}, {:px, 100})
    end

    test "rejects non-positive percent and scale" do
      assert {:error, {:invalid_operation, :resize, _}} =
               Operation.resize(:fit, {:percent, 0}, :auto)

      assert {:error, {:invalid_operation, :resize, _}} =
               Operation.resize(:fit, {:scale, -1.0}, :auto)
    end

    test "still accepts px and auto" do
      assert {:ok, %Resize{width: {:px, 300}, height: :auto}} =
               Operation.resize(:fit, {:px, 300}, :auto)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plan/operation_test.exs`
Expected: FAIL — `{:percent, 50}` currently hits `tagged_resize_dimension(_dimension) -> {:error, :dimension}`, so `resize/4` returns `{:error, {:invalid_operation, :resize, …}}`.

- [ ] **Step 3: Widen the struct type**

In `lib/image_pipe/plan/operation/resize.ex`, change line 18 from:

```elixir
  @type dimension :: :auto | {:px, pos_integer()}
```

to:

```elixir
  @type dimension :: :auto | {:px, pos_integer()} | {:percent, number()} | {:scale, number()}
```

- [ ] **Step 4: Add validated constructor clauses**

In `lib/image_pipe/plan/operation.ex`, replace the `tagged_resize_dimension/1` clauses (lines 493-498) with:

```elixir
  defp tagged_resize_dimension(:auto), do: {:ok, :auto}

  defp tagged_resize_dimension({:px, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp tagged_resize_dimension({:percent, value}) when is_number(value) and value > 0,
    do: {:ok, {:percent, value}}

  defp tagged_resize_dimension({:scale, value}) when is_number(value) and value > 0,
    do: {:ok, {:scale, value}}

  defp tagged_resize_dimension(_dimension), do: {:error, :dimension}
```

This flows through both `resize/4` (line 297) and `valid_resize?/1` (line 366) automatically.

- [ ] **Step 5: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/plan/operation_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/plan/operation/resize.ex lib/image_pipe/plan/operation.ex test/image_pipe/plan/operation_test.exs
git commit -m "feat(plan): allow percent/scale resize dimensions in semantic Resize"
```

### Task 1.2: Cache-key data for relative dimensions

**Files:**
- Modify: `lib/image_pipe/plan/key_data.ex:42-46` and after line 159
- Test: `test/image_pipe/plan/key_data_test.exs` (create if absent)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Plan.KeyDataTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.KeyData
  alias ImagePipe.Plan.Operation.Resize

  test "encodes percent and scale resize dimensions" do
    {:ok, op} = ImagePipe.Plan.Operation.resize(:fit, {:percent, 50}, {:scale, 0.5})
    data = KeyData.data(op)

    assert data[:width] == [unit: :percent, value: 50]
    assert data[:height] == [unit: :scale, value: 0.5]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/plan/key_data_test.exs`
Expected: FAIL — `KeyData.data({:percent, 50})` raises `FunctionClauseError` (no clause).

- [ ] **Step 3: Extend the geometry_value type**

In `lib/image_pipe/plan/key_data.ex`, change the `@type geometry_value` (lines 42-46) to:

```elixir
  @type geometry_value ::
          :auto
          | :full_axis
          | {:px, pos_integer()}
          | {:percent, number()}
          | {:scale, number()}
          | {:ratio, non_neg_integer(), pos_integer()}
```

- [ ] **Step 4: Add data/1 clauses**

In `lib/image_pipe/plan/key_data.ex`, immediately after the `{:px, value}` clause (line 158-159), add:

```elixir
  def data({:percent, value}) when is_number(value),
    do: [unit: :percent, value: value]

  def data({:scale, value}) when is_number(value),
    do: [unit: :scale, value: value]
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/plan/key_data_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/plan/key_data.ex test/image_pipe/plan/key_data_test.exs
git commit -m "feat(plan): include percent/scale resize dims in cache key data"
```

### Task 1.3: Resolve relative dimensions against the running image

**Files:**
- Modify: `lib/image_pipe/transform/operation/resize.ex` (type at lines 22-24; `resolve_dimensions/2` at line 77)
- Test: `test/image_pipe/transform/resize_dimension_test.exs` (append)

- [ ] **Step 1: Write the failing test**

Append to `test/image_pipe/transform/resize_dimension_test.exs`:

```elixir
  test "percent width resolves against the running source width" do
    operation = %Resize{mode: :fit, width: {:percent, 50}, height: :auto, enlarge: true}

    result = Resize.resolve_dimensions(operation, source_width: 340, source_height: 200)

    assert result.intermediate_width == 170
  end

  test "scale width resolves against the running source width" do
    operation = %Resize{mode: :fit, width: {:scale, 0.25}, height: :auto, enlarge: true}

    result = Resize.resolve_dimensions(operation, source_width: 400, source_height: 300)

    assert result.intermediate_width == 100
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/resize_dimension_test.exs`
Expected: FAIL — `normalize_bound_dimension({:percent, 50})` raises `FunctionClauseError`.

- [ ] **Step 3: Widen the executable dimension type**

In `lib/image_pipe/transform/operation/resize.ex`, change the `@type dimension()` (line 23) from:

```elixir
  @type dimension() :: :auto | pixels()
```

to:

```elixir
  @type dimension() :: :auto | pixels() | {:percent, number()} | {:scale, number()}
```

- [ ] **Step 4: Resolve relative dims at the head of resolve_dimensions/2**

In `lib/image_pipe/transform/operation/resize.ex`, change the start of `resolve_dimensions/2` (line 77-80) from:

```elixir
  def resolve_dimensions(%__MODULE__{} = operation, opts) when is_list(opts) do
    source = source_dimensions(opts)
    operation = normalize(operation)
```

to:

```elixir
  def resolve_dimensions(%__MODULE__{} = operation, opts) when is_list(opts) do
    source = source_dimensions(opts)
    operation = resolve_relative_dimensions(operation, source)
    operation = normalize(operation)
```

Then add these private functions (near `normalize/1`, around line 140). `to_pixels/2` is already imported via `import ImagePipe.Transform.Geometry` (line 18):

```elixir
  defp resolve_relative_dimensions(%__MODULE__{} = operation, source) do
    %__MODULE__{
      operation
      | width: resolve_relative_dimension(operation.width, source.width),
        height: resolve_relative_dimension(operation.height, source.height),
        min_width: resolve_relative_dimension(operation.min_width, source.width),
        min_height: resolve_relative_dimension(operation.min_height, source.height)
    }
  end

  defp resolve_relative_dimension({:percent, _} = unit, length),
    do: {:pixels, max(1, to_pixels(length, unit))}

  defp resolve_relative_dimension({:scale, _} = unit, length),
    do: {:pixels, max(1, to_pixels(length, unit))}

  defp resolve_relative_dimension(other, _length), do: other
```

Resolution happens before `normalize/1`, so `normalize_bound_dimension/1` only ever sees `:auto` / `{:pixels, _}` — no further widening needed there. All three `resolve_dimensions/2` callers (`execute/2`, `cover_resize_and_crop/4`, `resize_padding_scale/3`) pass the running image's dimensions as `source_width` / `source_height`.

- [ ] **Step 5: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/transform/resize_dimension_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/transform/operation/resize.ex test/image_pipe/transform/resize_dimension_test.exs
git commit -m "feat(transform): resolve percent/scale resize dims against running image"
```

### Task 1.4: PlanExecutor passes relative dims through to the executable Resize

**Files:**
- Modify: `lib/image_pipe/transform/plan_executor.ex:295-296`
- Test: `test/image_pipe/transform/plan_executor_test.exs` (append)

- [ ] **Step 1: Write the failing test**

Append to `test/image_pipe/transform/plan_executor_test.exs`. (Match the file's existing aliases/setup; this test builds a 2-op resize plan and checks the decoded dimensions.)

```elixir
  test "chained resize with a percent second op resolves against the running width" do
    {:ok, image} = Image.new(400, 300)
    state = %ImagePipe.Transform.State{image: image}

    {:ok, first} = ImagePipe.Plan.Operation.resize(:fit, {:px, 340}, :auto, enlargement: :allow)
    {:ok, second} = ImagePipe.Plan.Operation.resize(:fit, {:percent, 50}, :auto, enlargement: :allow)

    plan = %ImagePipe.Plan{
      source: %ImagePipe.Plan.Source.Path{segments: ["x"]},
      pipelines: [%ImagePipe.Plan.Pipeline{operations: [first, second]}],
      output: %ImagePipe.Plan.Output{mode: :automatic}
    }

    {:ok, %ImagePipe.Transform.State{image: result}} =
      ImagePipe.Transform.PlanExecutor.execute(plan, state, [])

    assert Image.width(result) == 170
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/plan_executor_test.exs`
Expected: FAIL — `tagged_executable_resize_dimension({:percent, 50})` raises `FunctionClauseError`.

- [ ] **Step 3: Add passthrough clauses**

In `lib/image_pipe/transform/plan_executor.ex`, replace `tagged_executable_resize_dimension/1` (lines 295-296) with:

```elixir
  defp tagged_executable_resize_dimension(:auto), do: :auto
  defp tagged_executable_resize_dimension({:px, value}), do: {:pixels, value}
  defp tagged_executable_resize_dimension({:percent, value}), do: {:percent, value}
  defp tagged_executable_resize_dimension({:scale, value}), do: {:scale, value}
```

The executable struct now carries the relative unit; `resolve_dimensions/2` (Task 1.3) resolves it. (`tagged_logical_pixels/1` returns `:unknown` for relative units, so an `:auto`-mode resize with a relative dim routes to `:fit` — the TwicPics parser never emits `:auto`, so this is unreachable here; left as-is by design.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/transform/plan_executor_test.exs`
Expected: PASS (170px — proves running-dimension resolution end-to-end).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/plan_executor.ex test/image_pipe/transform/plan_executor_test.exs
git commit -m "feat(transform): thread percent/scale resize dims through PlanExecutor"
```

### Task 1.5: DecodePlanner treats relative resize dims as random-access (explicit)

**Files:**
- Modify: `lib/image_pipe/transform/decode_planner.ex:81-82`
- Test: `test/image_pipe/transform/decode_planner_test.exs` (create if absent)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Transform.DecodePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.DecodePlanner

  test "a relative-unit resize plans random access, never sequential" do
    {:ok, op} = ImagePipe.Plan.Operation.resize(:fit, {:percent, 50}, :auto)

    assert DecodePlanner.open_options([op])[:access] == :random
  end

  test "a literal-px fit resize still plans sequential" do
    {:ok, op} = ImagePipe.Plan.Operation.resize(:fit, {:px, 300}, :auto)

    assert DecodePlanner.open_options([op])[:access] == :sequential
  end
end
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run: `mise exec -- mix test test/image_pipe/transform/decode_planner_test.exs`
Expected: PASS already (relative units fall through to `false → :random`). This test **pins** the conservative invariant required by CLAUDE.md's decode-safety rule; the next step makes it explicit in code.

- [ ] **Step 3: Make the invariant explicit**

In `lib/image_pipe/transform/decode_planner.ex`, replace `requested_resize_dimension?/1` (lines 81-82) with:

```elixir
  defp requested_resize_dimension?({:px, value}) when is_integer(value) and value > 0, do: true
  # Relative units (percent/scale) resolve against the running image at execute
  # time, so a relative-unit resize is never treated as sequential-access.
  defp requested_resize_dimension?({:percent, _value}), do: false
  defp requested_resize_dimension?({:scale, _value}), do: false
  defp requested_resize_dimension?(_dimension), do: false
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/image_pipe/transform/decode_planner_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the full core gate**

Run: `mise exec -- mix test test/image_pipe/plan test/image_pipe/transform`
Expected: PASS (no regressions in existing resize/keydata/decode tests).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/transform/decode_planner.ex test/image_pipe/transform/decode_planner_test.exs
git commit -m "feat(transform): pin relative resize dims to random-access decode"
```

---

## Phase 2 — TwicPics parser

All modules under `lib/image_pipe/parser/twic_pics/` with the top module at `lib/image_pipe/parser/twic_pics.ex` (the boundary-test file map uses `twic_pics.ex`). Parser unit tests under `test/parser/twic_pics/`.

### Task 2.1: Units — Length parsing

**Files:**
- Create: `lib/image_pipe/parser/twic_pics/units.ex`
- Test: `test/parser/twic_pics/units_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Parser.TwicPics.UnitsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.Units

  describe "length/1" do
    test "bare and px numbers are pixels" do
      assert Units.length("250") == {:ok, {:px, 250}}
      assert Units.length("250px") == {:ok, {:px, 250}}
    end

    test "percent suffix" do
      assert Units.length("50p") == {:ok, {:percent, 50}}
      assert Units.length("4.5p") == {:ok, {:percent, 4.5}}
    end

    test "scale suffix" do
      assert Units.length("0.5s") == {:ok, {:scale, 0.5}}
    end

    test "rejects malformed and non-positive pixels" do
      assert {:error, _} = Units.length("abc")
      assert {:error, _} = Units.length("0")
      assert {:error, _} = Units.length("-3")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/parser/twic_pics/units_test.exs`
Expected: FAIL — module does not exist.

- [ ] **Step 3: Implement Length parsing**

```elixir
defmodule ImagePipe.Parser.TwicPics.Units do
  @moduledoc false

  @type length :: {:px, pos_integer()} | {:percent, number()} | {:scale, number()}

  @spec length(String.t()) :: {:ok, length()} | {:error, term()}
  def length("-"), do: {:error, {:invalid_length, "-"}}

  def length(value) when is_binary(value) do
    cond do
      String.ends_with?(value, "px") -> pixels(String.trim_trailing(value, "px"))
      String.ends_with?(value, "p") -> percent(String.trim_trailing(value, "p"))
      String.ends_with?(value, "s") -> scale(String.trim_trailing(value, "s"))
      true -> pixels(value)
    end
  end

  defp pixels(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, {:px, n}}
      _ -> {:error, {:invalid_length, value}}
    end
  end

  defp percent(value) do
    with {:ok, n} <- number(value), true <- n > 0 do
      {:ok, {:percent, n}}
    else
      _ -> {:error, {:invalid_length, value}}
    end
  end

  defp scale(value) do
    with {:ok, n} <- number(value), true <- n > 0 do
      {:ok, {:scale, n}}
    else
      _ -> {:error, {:invalid_length, value}}
    end
  end

  @doc false
  @spec number(String.t()) :: {:ok, number()} | :error
  def number(value) do
    case Integer.parse(value) do
      {n, ""} ->
        {:ok, n}

      _ ->
        case Float.parse(value) do
          {n, ""} -> {:ok, n}
          _ -> :error
        end
    end
  end
end
```

Note: submodules carry **no** `use Boundary` declaration. The Boundary library classifies them into the `ImagePipe.Parser.TwicPics` boundary automatically by the `ImagePipe.Parser.TwicPics.*` name prefix — exactly as the imgproxy submodules (`parser/imgproxy/*.ex`) do. (`classify_to:` is only valid for protocol implementations and mix tasks, so it must NOT be used here.)

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/parser/twic_pics/units_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/twic_pics/units.ex test/parser/twic_pics/units_test.exs
git commit -m "feat(twicpics): Units.length parsing (px/percent/scale)"
```

### Task 2.2: Units — size, crop-size, ratio, coordinates, anchor

**Files:**
- Modify: `lib/image_pipe/parser/twic_pics/units.ex`
- Test: `test/parser/twic_pics/units_test.exs` (append)

- [ ] **Step 1: Write the failing tests**

```elixir
  describe "size/1 (resize/cover/contain/inside)" do
    test "WxH, single dim (auto), and dash-auto" do
      assert Units.size("250x100") == {:ok, {{:px, 250}, {:px, 100}}}
      assert Units.size("250") == {:ok, {{:px, 250}, :auto}}
      assert Units.size("-x100") == {:ok, {:auto, {:px, 100}}}
      assert Units.size("250x-") == {:ok, {{:px, 250}, :auto}}
    end
  end

  describe "crop_size/1" do
    test "omitted dimension is the full axis (1s), not aspect auto" do
      assert Units.crop_size("320") == {:ok, {{:px, 320}, :full_axis}}
      assert Units.crop_size("320x-") == {:ok, {{:px, 320}, :full_axis}}
      assert Units.crop_size("-x240") == {:ok, {:full_axis, {:px, 240}}}
    end
  end

  describe "ratio/1" do
    test "two positive numbers" do
      assert Units.ratio("16:9") == {:ok, {:ratio, 16, 9}}
    end

    test "rejects non-positive" do
      assert {:error, _} = Units.ratio("0:9")
    end
  end

  describe "coordinates/1" do
    test "two lengths" do
      assert Units.coordinates("20x50") == {:ok, {{:px, 20}, {:px, 50}}}
    end
  end

  describe "anchor/1" do
    test "the eight anchors map to plan guides" do
      assert Units.anchor("top-left") == {:ok, {:anchor, :left, :top}}
      assert Units.anchor("top") == {:ok, {:anchor, :center, :top}}
      assert Units.anchor("bottom-right") == {:ok, {:anchor, :right, :bottom}}
      assert Units.anchor("left") == {:ok, {:anchor, :left, :center}}
    end

    test "center is not a valid anchor" do
      assert {:error, _} = Units.anchor("center")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/parser/twic_pics/units_test.exs`
Expected: FAIL — `size/1` etc. undefined.

- [ ] **Step 3: Implement**

Append to `lib/image_pipe/parser/twic_pics/units.ex`:

```elixir
  @spec size(String.t()) :: {:ok, {length() | :auto, length() | :auto}} | {:error, term()}
  def size(value), do: pair(value, :auto)

  @spec crop_size(String.t()) :: {:ok, {length() | :full_axis, length() | :full_axis}} | {:error, term()}
  def crop_size(value), do: pair(value, :full_axis)

  defp pair(value, omitted) do
    case String.split(value, "x", parts: 2) do
      [single] -> with {:ok, w} <- dimension(single, omitted), do: {:ok, {w, omitted}}
      [w, h] -> with {:ok, w} <- dimension(w, omitted), {:ok, h} <- dimension(h, omitted), do: {:ok, {w, h}}
    end
  end

  defp dimension("-", omitted), do: {:ok, omitted}
  defp dimension("", omitted), do: {:ok, omitted}
  defp dimension(value, _omitted), do: length(value)

  @spec ratio(String.t()) :: {:ok, {:ratio, pos_integer(), pos_integer()}} | {:error, term()}
  def ratio(value) do
    with [w, h] <- String.split(value, ":", parts: 2),
         {:ok, n} <- positive_ratio_term(w),
         {:ok, d} <- positive_ratio_term(h) do
      {:ok, {:ratio, n, d}}
    else
      _ -> {:error, {:invalid_ratio, value}}
    end
  end

  defp positive_ratio_term(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  @spec coordinates(String.t()) :: {:ok, {length(), length()}} | {:error, term()}
  def coordinates(value) do
    with [x, y] <- String.split(value, "x", parts: 2),
         {:ok, x} <- length(x),
         {:ok, y} <- length(y) do
      {:ok, {x, y}}
    else
      _ -> {:error, {:invalid_coordinates, value}}
    end
  end

  @anchors %{
    "top" => {:anchor, :center, :top},
    "bottom" => {:anchor, :center, :bottom},
    "left" => {:anchor, :left, :center},
    "right" => {:anchor, :right, :center},
    "top-left" => {:anchor, :left, :top},
    "top-right" => {:anchor, :right, :top},
    "bottom-left" => {:anchor, :left, :bottom},
    "bottom-right" => {:anchor, :right, :bottom}
  }

  @spec anchor(String.t()) :: {:ok, {:anchor, atom(), atom()}} | {:error, term()}
  def anchor(value) do
    case Map.fetch(@anchors, value) do
      {:ok, guide} -> {:ok, guide}
      :error -> {:error, {:invalid_anchor, value}}
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/parser/twic_pics/units_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/twic_pics/units.ex test/parser/twic_pics/units_test.exs
git commit -m "feat(twicpics): Units size/crop_size/ratio/coordinates/anchor"
```

### Task 2.3: Manipulation — split the `v1/` chain

**Files:**
- Create: `lib/image_pipe/parser/twic_pics/manipulation.ex`
- Test: `test/parser/twic_pics/manipulation_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Parser.TwicPics.ManipulationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.Manipulation

  test "splits an ordered v1 chain into name/args segments" do
    assert Manipulation.parse("v1/focus=top/cover=100x100/output=avif") ==
             {:ok, [{"focus", "top"}, {"cover", "100x100"}, {"output", "avif"}]}
  end

  test "requires the v1 prefix" do
    assert {:error, {:unsupported_manipulation_version, _}} = Manipulation.parse("v2/resize=10")
    assert {:error, {:unsupported_manipulation_version, _}} = Manipulation.parse("resize=10")
  end

  test "rejects a segment without =" do
    assert {:error, {:invalid_segment, "resize"}} = Manipulation.parse("v1/resize")
  end

  test "ignores empty segments from stray slashes" do
    assert {:ok, [{"resize", "10"}]} = Manipulation.parse("v1/resize=10/")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/parser/twic_pics/manipulation_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement**

```elixir
defmodule ImagePipe.Parser.TwicPics.Manipulation do
  @moduledoc false

  @spec parse(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def parse("v1/" <> rest), do: segments(rest)
  def parse("v1"), do: {:ok, []}
  def parse(other), do: {:error, {:unsupported_manipulation_version, other}}

  defp segments(rest) do
    rest
    |> String.split("/", trim: true)
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, acc} ->
      case String.split(segment, "=", parts: 2) do
        [name, args] -> {:cont, {:ok, [{name, args} | acc]}}
        [name] -> {:halt, {:error, {:invalid_segment, name}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/parser/twic_pics/manipulation_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/twic_pics/manipulation.ex test/parser/twic_pics/manipulation_test.exs
git commit -m "feat(twicpics): Manipulation chain envelope split"
```

### Task 2.4: Source + Path — request path to `Source.Path`, twic extraction

**Files:**
- Create: `lib/image_pipe/parser/twic_pics/source.ex`
- Create: `lib/image_pipe/parser/twic_pics/path.ex`
- Test: `test/parser/twic_pics/path_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Parser.TwicPics.PathTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Parser.TwicPics.Path
  alias ImagePipe.Plan.Source

  test "builds a Source.Path from path_info and extracts the twic chain" do
    conn = conn(:get, "/images/beach.jpg?twic=v1/resize=100")

    assert {:ok, %Source.Path{segments: ["images", "beach.jpg"]}, "v1/resize=100"} =
             Path.extract(conn)
  end

  test "missing twic param is an error" do
    conn = conn(:get, "/images/beach.jpg")
    assert {:error, :missing_manipulation} = Path.extract(conn)
  end

  test "empty source path is an error" do
    conn = conn(:get, "/?twic=v1/resize=100")
    assert {:error, :invalid_source_path} = Path.extract(conn)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/parser/twic_pics/path_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 3: Implement Source and Path**

`lib/image_pipe/parser/twic_pics/source.ex`:

```elixir
defmodule ImagePipe.Parser.TwicPics.Source do
  @moduledoc false

  alias ImagePipe.Plan.Source.Path, as: SourcePath

  @spec from_segments([String.t()]) :: {:ok, SourcePath.t()} | {:error, term()}
  def from_segments([]), do: {:error, :invalid_source_path}

  def from_segments(segments) do
    if Enum.any?(segments, &(&1 == "")) do
      {:error, :invalid_source_path}
    else
      decode(segments)
    end
  end

  defp decode(segments) do
    decoded = Enum.map(segments, &URI.decode/1)
    {:ok, %SourcePath{segments: decoded}}
  end
end
```

`lib/image_pipe/parser/twic_pics/path.ex`:

```elixir
defmodule ImagePipe.Parser.TwicPics.Path do
  @moduledoc false

  alias ImagePipe.Parser.TwicPics.Source
  alias ImagePipe.Plan.Source.Path, as: SourcePath

  @spec extract(Plug.Conn.t()) :: {:ok, SourcePath.t(), String.t()} | {:error, term()}
  def extract(%Plug.Conn{} = conn) do
    with {:ok, manipulation} <- fetch_manipulation(conn),
         {:ok, source} <- Source.from_segments(conn.path_info) do
      {:ok, source, manipulation}
    end
  end

  defp fetch_manipulation(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case Map.get(conn.query_params, "twic") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_manipulation}
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/parser/twic_pics/path_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/twic_pics/source.ex lib/image_pipe/parser/twic_pics/path.ex test/parser/twic_pics/path_test.exs
git commit -m "feat(twicpics): Path/Source extraction to Source.Path + twic chain"
```

### Task 2.5: Output — `output=` / `quality=` to `Plan.Output`

**Files:**
- Create: `lib/image_pipe/parser/twic_pics/output.ex`
- Test: `test/parser/twic_pics/output_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Parser.TwicPics.OutputTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.Output
  alias ImagePipe.Plan.Output, as: PlanOutput

  test "auto, explicit formats, and quality" do
    assert Output.build(%{format: :auto, quality: :default}) ==
             {:ok, %PlanOutput{mode: :automatic, quality: :default}}

    assert Output.build(%{format: :avif, quality: {:quality, 80}}) ==
             {:ok, %PlanOutput{mode: {:explicit, :avif}, quality: {:quality, 80}}}
  end

  test "parse format and quality strings" do
    assert Output.format("auto") == {:ok, :auto}
    assert Output.format("webp") == {:ok, :webp}
    assert {:error, _} = Output.format("blurhash")
    assert Output.quality("80") == {:ok, {:quality, 80}}
    assert {:error, _} = Output.quality("0")
    assert {:error, _} = Output.quality("101")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/parser/twic_pics/output_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement**

```elixir
defmodule ImagePipe.Parser.TwicPics.Output do
  @moduledoc false

  alias ImagePipe.Plan.Output, as: PlanOutput

  @formats %{"auto" => :auto, "avif" => :avif, "webp" => :webp, "jpeg" => :jpeg, "png" => :png}

  @spec format(String.t()) :: {:ok, atom()} | {:error, term()}
  def format(value) do
    case Map.fetch(@formats, value) do
      {:ok, format} -> {:ok, format}
      :error -> {:error, {:unsupported_output, value}}
    end
  end

  @spec quality(String.t()) :: {:ok, {:quality, 1..100}} | {:error, term()}
  def quality(value) do
    case Integer.parse(value) do
      {n, ""} when n in 1..100 -> {:ok, {:quality, n}}
      _ -> {:error, {:invalid_quality, value}}
    end
  end

  @spec build(%{format: atom(), quality: PlanOutput.quality()}) :: {:ok, PlanOutput.t()}
  def build(%{format: :auto, quality: quality}),
    do: {:ok, %PlanOutput{mode: :automatic, quality: quality}}

  def build(%{format: format, quality: quality}),
    do: {:ok, %PlanOutput{mode: {:explicit, format}, quality: quality}}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/parser/twic_pics/output_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/twic_pics/output.ex test/parser/twic_pics/output_test.exs
git commit -m "feat(twicpics): Output format/quality mapping"
```

### Task 2.6: PlanBuilder — fold the chain into a Plan

This is the heart of the parser. It folds the ordered `[{name, args}]` into an accumulator (`%{ops: [...], guide: guide, format: :auto, quality: :default}`), emitting `Plan.Operation.*` via constructors, then assembles the `%Plan{}`.

**Files:**
- Create: `lib/image_pipe/parser/twic_pics/plan_builder.ex`
- Test: `test/parser/twic_pics/plan_builder_test.exs`

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule ImagePipe.Parser.TwicPics.PlanBuilderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.PlanBuilder
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source

  defp build(chain), do: PlanBuilder.to_plan(%Source.Path{segments: ["x.jpg"]}, chain)

  test "resize single dim -> fit auto; WxH -> stretch" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [r1]}]}} = build([{"resize", "100"}])
    assert %Operation.Resize{mode: :fit, width: {:px, 100}, height: :auto} = r1

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [r2]}]}} = build([{"resize", "100x50"}])
    assert %Operation.Resize{mode: :stretch, width: {:px, 100}, height: {:px, 50}} = r2
  end

  test "relative-unit resize is emitted as one op per segment (no static collapse)" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [a, b]}]}} =
             build([{"resize", "340"}, {"resize", "50p"}])

    assert %Operation.Resize{width: {:px, 340}} = a
    assert %Operation.Resize{width: {:percent, 50}} = b
  end

  test "focus anchor steers the next cover" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [cover]}]}} =
             build([{"focus", "top"}, {"cover", "100x100"}])

    assert %Operation.Resize{mode: :cover, guide: {:anchor, :center, :top}} = cover
  end

  test "cover ratio -> guided ratio crop" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [crop]}]}} = build([{"cover", "16:9"}])

    assert %Operation.CropGuided{width: :full_axis, height: :full_axis, aspect_ratio: {:ratio, 16, 9}} =
             crop
  end

  test "inside -> fit resize plus transparent canvas" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [resize, canvas]}]}} =
             build([{"inside", "100x80"}])

    assert %Operation.Resize{mode: :fit} = resize
    assert %Operation.Canvas{fill: :transparent} = canvas
  end

  test "crop without coords uses the guide; with coords resets to center and emits CropRegion" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [guided]}]}} =
             build([{"focus", "top"}, {"crop", "100x100"}])

    assert %Operation.CropGuided{guide: {:anchor, :center, :top}} = guided

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [region, after_crop]}]}} =
             build([{"crop", "100x100@20x50"}, {"cover", "10x10"}])

    assert %Operation.CropRegion{x: {:px, 20}, y: {:px, 50}, width: {:px, 100}, height: {:px, 100}} = region
    assert %Operation.Resize{mode: :cover, guide: :center} = after_crop
  end

  test "output/quality last-wins, applied to Output not the pipeline" do
    assert {:ok, %Plan{output: %Output{mode: {:explicit, :webp}, quality: {:quality, 70}}}} =
             build([{"resize", "10"}, {"output", "avif"}, {"output", "webp"}, {"quality", "70"}])
  end

  test "rejected non-goals fail the whole build" do
    assert {:error, {:unsupported_transform, "zoom"}} = build([{"zoom", "2"}])
    assert {:error, _} = build([{"resize", "16:9"}])
    assert {:error, _} = build([{"focus", "auto"}])
    assert {:error, _} = build([{"focus", "center"}])
  end

  test "relative units on crop/inside are rejected in v1 (pixel-only)" do
    assert {:error, {:unsupported_unit, :inside}} = build([{"inside", "50p"}])
    assert {:error, {:unsupported_unit, :crop}} = build([{"crop", "50p"}])
  end

  test "an empty pipeline still produces a valid no-op plan when only output is set" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} = build([{"output", "auto"}])
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/parser/twic_pics/plan_builder_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement PlanBuilder**

```elixir
defmodule ImagePipe.Parser.TwicPics.PlanBuilder do
  @moduledoc false

  alias ImagePipe.Parser.TwicPics.Output
  alias ImagePipe.Parser.TwicPics.Units
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source

  @initial %{ops: [], guide: :center, format: :auto, quality: :default}

  @spec to_plan(Source.t(), [{String.t(), String.t()}]) :: {:ok, Plan.t()} | {:error, term()}
  def to_plan(source, chain) when is_list(chain) do
    with {:ok, acc} <- fold(chain),
         {:ok, output} <- Output.build(%{format: acc.format, quality: acc.quality}) do
      {:ok,
       %Plan{
         source: source,
         pipelines: [%Pipeline{operations: Enum.reverse(acc.ops)}],
         output: output
       }}
    end
  end

  defp fold(chain) do
    Enum.reduce_while(chain, {:ok, @initial}, fn {name, args}, {:ok, acc} ->
      case apply_segment(name, args, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # --- geometry ---

  defp apply_segment("resize", args, acc), do: resize(args, acc)
  defp apply_segment("cover", args, acc), do: cover(args, acc)
  defp apply_segment("contain", args, acc), do: contain(args, acc)
  defp apply_segment("inside", args, acc), do: inside(args, acc)
  defp apply_segment("crop", args, acc), do: crop(args, acc)
  defp apply_segment("focus", args, acc), do: focus(args, acc)
  defp apply_segment("output", args, acc), do: output(args, acc)
  defp apply_segment("quality", args, acc), do: quality(args, acc)
  defp apply_segment(name, _args, _acc), do: {:error, {:unsupported_transform, name}}

  defp resize(args, acc) do
    if String.contains?(args, ":") do
      {:error, {:unsupported_transform_ratio, "resize"}}
    else
      with {:ok, {w, h}} <- Units.size(args),
           {mode, w, h} <- resize_mode(w, h),
           {:ok, op} <- Operation.resize(mode, w, h) do
        push(acc, op)
      end
    end
  end

  defp resize_mode(w, :auto), do: {:fit, w, :auto}
  defp resize_mode(:auto, h), do: {:fit, :auto, h}
  defp resize_mode(w, h), do: {:stretch, w, h}

  defp cover(args, acc) do
    if String.contains?(args, ":") do
      with {:ok, {:ratio, _, _} = ratio} <- Units.ratio(args),
           {:ok, op} <-
             Operation.crop_guided(:full_axis, :full_axis, acc.guide, aspect_ratio: ratio) do
        push(acc, op)
      end
    else
      with {:ok, {w, h}} <- Units.size(args),
           {:ok, op} <- Operation.resize(:cover, w, h, guide: acc.guide) do
        push(acc, op)
      end
    end
  end

  defp contain(args, acc) do
    with {:ok, {w, h}} <- Units.size(args),
         {:ok, op} <- Operation.resize(:fit, w, h) do
      push(acc, op)
    end
  end

  defp inside(args, acc) do
    if String.contains?(args, ":") do
      {:error, {:unsupported_transform_ratio, "inside"}}
    else
      with {:ok, {w, h}} <- Units.size(args),
           :ok <- pixels_only([w, h], :inside),
           {:ok, resize} <- Operation.resize(:fit, w, h),
           {:ok, canvas} <- Operation.canvas(w, h, :center, fill: :transparent) do
        acc |> push(resize) |> then(fn {:ok, acc} -> push(acc, canvas) end)
      end
    end
  end

  defp crop(args, acc) do
    case String.split(args, "@", parts: 2) do
      [size] -> crop_guided(size, acc)
      [size, coords] -> crop_region(size, coords, acc)
    end
  end

  defp crop_guided(size, acc) do
    with {:ok, {w, h}} <- Units.crop_size(size),
         :ok <- pixels_only([w, h], :crop),
         {:ok, op} <- Operation.crop_guided(w, h, acc.guide) do
      push(acc, op)
    end
  end

  defp crop_region(size, coords, acc) do
    with {:ok, {w, h}} <- Units.size(size),
         :ok <- pixels_only([w, h], :crop),
         {:ok, {x, y}} <- crop_coordinates(coords),
         {:ok, op} <- Operation.crop_region(x, y, w, h) do
      # explicit coordinates reset the focus to center
      push(%{acc | guide: :center}, op)
    end
  end

  # v1: crop/inside accept pixel dimensions only (crop also :full_axis for an
  # omitted axis). Relative units (percent/scale) on crop/inside are deferred —
  # resize/cover/contain carry full relative-unit support.
  defp pixels_only(dims, transform) do
    if Enum.all?(dims, &pixel_dimension?/1),
      do: :ok,
      else: {:error, {:unsupported_unit, transform}}
  end

  defp pixel_dimension?({:px, _}), do: true
  defp pixel_dimension?(:auto), do: true
  defp pixel_dimension?(:full_axis), do: true
  defp pixel_dimension?(_), do: false

  # v1 crop coordinates: pixels only (percent/scale coords deferred)
  defp crop_coordinates(coords) do
    with {:ok, {{:px, _} = x, {:px, _} = y}} <- Units.coordinates(coords) do
      {:ok, {x, y}}
    else
      _ -> {:error, {:unsupported_crop_coordinates, coords}}
    end
  end

  defp focus("auto", _acc), do: {:error, {:unsupported_focus, "auto"}}
  defp focus("center", _acc), do: {:error, {:unsupported_focus, "center"}}

  defp focus(args, acc) do
    case Units.anchor(args) do
      {:ok, guide} -> {:ok, %{acc | guide: guide}}
      {:error, _} -> {:error, {:unsupported_focus, args}}
    end
  end

  defp output(args, acc) do
    with {:ok, format} <- Output.format(args), do: {:ok, %{acc | format: format}}
  end

  defp quality(args, acc) do
    with {:ok, quality} <- Output.quality(args), do: {:ok, %{acc | quality: quality}}
  end

  defp push(acc, op), do: {:ok, %{acc | ops: [op | acc.ops]}}
end
```

Constructor signatures (verified against `lib/image_pipe/plan/operation.ex`): `crop_guided(width, height, guide, opts \\ [])` (line 172 — 3-arg and 4-arg both valid), `crop_region(x, y, width, height)` (line 203), `canvas(width, height, placement, opts \\ [])` (line 215 — `placement` is **positional**, fill is an opt), `resize(mode, width, height, opts \\ [])` (line 292).

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/parser/twic_pics/plan_builder_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/twic_pics/plan_builder.ex test/parser/twic_pics/plan_builder_test.exs
git commit -m "feat(twicpics): PlanBuilder folds the chain into a Plan"
```

### Task 2.7: Top module — behaviour, parse/2, handle_error/2, validate_options!/1, Boundary

**Files:**
- Create: `lib/image_pipe/parser/twic_pics.ex`
- Test: `test/parser/twic_pics_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Parser.TwicPicsTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Parser.TwicPics
  alias ImagePipe.Plan

  test "parse/2 returns a Plan for a valid twic request" do
    conn = conn(:get, "/images/beach.jpg?twic=v1/resize=100/output=avif")

    assert {:ok, %Plan{output: %Plan.Output{mode: {:explicit, :avif}}}} = TwicPics.parse(conn, [])
  end

  test "parse/2 returns an error for an unsupported transform" do
    conn = conn(:get, "/images/beach.jpg?twic=v1/zoom=2")
    assert {:error, {:unsupported_transform, "zoom"}} = TwicPics.parse(conn, [])
  end

  test "handle_error/2 sends a 400 text response" do
    conn = conn(:get, "/x?twic=v1/zoom=2")
    result = TwicPics.handle_error(conn, {:error, {:unsupported_transform, "zoom"}})

    assert result.status == 400
    assert get_resp_header(result, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "validate_options!/1 returns the validated keyword list" do
    assert TwicPics.validate_options!([]) == []
  end

  test "validate_options!/1 raises on a non-list" do
    assert_raise ArgumentError, fn -> TwicPics.validate_options!(:nope) end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/parser/twic_pics_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement**

```elixir
defmodule ImagePipe.Parser.TwicPics do
  @moduledoc """
  Parser for the TwicPics `?twic=v1/…` URL dialect.

  See `docs/twicpics_support_matrix.md` for the supported surface.
  """

  use Boundary,
    deps: [ImagePipe.Parser, ImagePipe.Plan],
    exports: []

  @behaviour ImagePipe.Parser

  alias ImagePipe.Parser.TwicPics.Manipulation
  alias ImagePipe.Parser.TwicPics.Path
  alias ImagePipe.Parser.TwicPics.PlanBuilder

  @schema NimbleOptions.new!([])

  @doc false
  def validate_options!(opts) when is_list(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, validated} -> validated
      {:error, error} -> raise ArgumentError, "invalid twicpics config: #{Exception.message(error)}"
    end
  end

  def validate_options!(_opts),
    do: raise(ArgumentError, "invalid twicpics options: expected a keyword list")

  @impl ImagePipe.Parser
  def parse(%Plug.Conn{} = conn, _opts) do
    with {:ok, source, manipulation} <- Path.extract(conn),
         {:ok, chain} <- Manipulation.parse(manipulation) do
      PlanBuilder.to_plan(source, chain)
    end
  end

  @impl ImagePipe.Parser
  def handle_error(%Plug.Conn{} = conn, {:error, reason}) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(400, "invalid image request: #{inspect(reason)}")
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/parser/twic_pics_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the whole parser suite + compile with warnings as errors**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/parser/twic_pics test/parser/twic_pics_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/parser/twic_pics.ex test/parser/twic_pics_test.exs
git commit -m "feat(twicpics): top parser module (parse/2, handle_error/2, validate_options!/1)"
```

---

## Phase 3 — Wiring & boundaries

### Task 3.1: Export the parser and wire config validation

**Files:**
- Modify: `lib/image_pipe/parser.ex:12`
- Modify: `lib/image_pipe/plug.ex` (alias near line 22; new `validate_parser_options/2` clause near line 198)

- [ ] **Step 1: Add the export**

In `lib/image_pipe/parser.ex`, change `exports: [Imgproxy]` (line 12) to:

```elixir
    exports: [Imgproxy, TwicPics]
```

- [ ] **Step 2: Add the alias and validation clause in the Plug**

In `lib/image_pipe/plug.ex`, add near the existing `alias ImagePipe.Parser.Imgproxy` (line 22):

```elixir
  alias ImagePipe.Parser.TwicPics
```

And add a `validate_parser_options/2` clause immediately before the catch-all `defp validate_parser_options(_parser, opts), do: opts` (line 207):

```elixir
  defp validate_parser_options(TwicPics, opts) do
    twicpics_opts =
      opts
      |> Keyword.get(:twicpics, [])
      |> TwicPics.validate_options!()

    Keyword.put(opts, :twicpics, twicpics_opts)
  end
```

- [ ] **Step 3: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: success (no Boundary violations, no unused-alias warnings).

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/parser.ex lib/image_pipe/plug.ex
git commit -m "feat(twicpics): export parser and wire config validation in the plug"
```

### Task 3.2: Architecture boundary test

**Files:**
- Modify: `test/image_pipe/architecture_boundary_test.exs` (`@boundary_files` ~line 37; parser test block lines 83-105)

- [ ] **Step 1: Add the file-map entry**

In `test/image_pipe/architecture_boundary_test.exs`, add to `@boundary_files` after the Imgproxy line (line 37):

```elixir
    ImagePipe.Parser.TwicPics => "lib/image_pipe/parser/twic_pics.ex",
```

- [ ] **Step 2: Update the parser boundary test**

Replace the body of `test "parser boundary declarations stay limited to format, parser, and plan APIs"` (lines 83-105) with one that also asserts the TwicPics boundary and the widened Parser exports:

```elixir
    parser = boundary_declaration(ImagePipe.Parser)
    imgproxy = boundary_declaration(ImagePipe.Parser.Imgproxy)
    twicpics = boundary_declaration(ImagePipe.Parser.TwicPics)

    assert_boundary_deps(parser, [ImagePipe.Format, ImagePipe.Plan])
    assert_boundary_exports(parser, [ImagePipe.Parser.Imgproxy, ImagePipe.Parser.TwicPics])

    assert_boundary_deps(imgproxy, [ImagePipe.Format, ImagePipe.Parser, ImagePipe.Plan])
    assert_boundary_exports(imgproxy, [ImagePipe.Parser.Imgproxy.SourceScheme])

    assert_boundary_deps(twicpics, [ImagePipe.Parser, ImagePipe.Plan])
    assert_boundary_exports(twicpics, [])

    assert_allowed_deps(parser, [ImagePipe.Format, ImagePipe.Plan])
    assert_allowed_deps(imgproxy, [ImagePipe.Format, ImagePipe.Parser, ImagePipe.Plan])
    assert_allowed_deps(twicpics, [ImagePipe.Parser, ImagePipe.Plan])
```

- [ ] **Step 3: Run the architecture test**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS — including the glob-driven "parser code does not depend on executable transform operation modules" test, which now covers the new `parser/twic_pics/**` files automatically.

- [ ] **Step 4: Commit**

```bash
git add test/image_pipe/architecture_boundary_test.exs
git commit -m "test(twicpics): assert parser boundary declarations"
```

---

## Phase 4 — Wire-level conformance tests

These make real `ImagePipe.Plug` requests through the same in-process origin pattern the imgproxy conformance suite uses (`RootHTTPAdapter` + `req_options: [plug: …]`). Reuse `priv/static/images/beach.jpg` (**4000×2667**).

### Task 4.1: Test support origin + headline running-dimension cases

**Files:**
- Create: `test/support/image_pipe/twic_pics_wire_conformance_test/origin_image.ex`
- Create: `test/support/image_pipe/twic_pics_wire_conformance_test/origin_should_not_fetch.ex`
- Create: `test/image_pipe/twic_pics_wire_conformance_test.exs`

- [ ] **Step 1: Create the origin support modules**

`test/support/image_pipe/twic_pics_wire_conformance_test/origin_image.ex`:

```elixir
defmodule TwicPicsWireConformanceTest.OriginImage do
  @moduledoc false

  use Boundary, top_level?: true, deps: []

  def init(opts), do: opts

  def call(conn, opts) do
    if pid = opts[:test_pid], do: send(pid, :origin_fetch)
    body = File.read!("priv/static/images/beach.jpg")

    conn
    |> Plug.Conn.put_resp_content_type("image/jpeg")
    |> Plug.Conn.send_resp(200, body)
  end
end
```

`test/support/image_pipe/twic_pics_wire_conformance_test/origin_should_not_fetch.ex`:

```elixir
defmodule TwicPicsWireConformanceTest.OriginShouldNotFetch do
  @moduledoc false

  use Boundary, top_level?: true, deps: []

  def init(opts), do: opts
  def call(_conn, _opts), do: raise("origin should not fetch")
end
```

- [ ] **Step 2: Write the failing wire tests**

`test/image_pipe/twic_pics_wire_conformance_test.exs`:

```elixir
defmodule ImagePipe.TwicPicsWireConformanceTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias TwicPicsWireConformanceTest.OriginImage
  alias TwicPicsWireConformanceTest.OriginShouldNotFetch
  alias Vix.Vips.Image, as: VipsImage

  @opts [
    parser: ImagePipe.Parser.TwicPics,
    sources: [
      path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
    ]
  ]

  defp call(path, opts \\ @opts) do
    :get |> conn(path) |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))
  end

  defp dimensions(%Plug.Conn{} = conn) do
    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    {Image.width(image), Image.height(image)}
  end

  test "single resize reaches the intermediate dimension (not clamped on a large source)" do
    conn = call("/images/beach.jpg?twic=v1/resize=340/output=jpeg")
    assert {340, _} = dimensions(conn)
  end

  test "chained relative resize resolves against running dimensions (340 then 50%)" do
    conn = call("/images/beach.jpg?twic=v1/resize=340/resize=50p/output=jpeg")
    assert conn.status == 200
    # 170 = 50% of the running 340 (proven reachable by the test above), not 50% of source 4000
    assert {170, _} = dimensions(conn)
  end

  test "three-hop relative chain compounds against the running width" do
    conn = call("/images/beach.jpg?twic=v1/resize=340/resize=50p/resize=50p/output=jpeg")
    assert {85, _} = dimensions(conn)
  end

  test "bare percent resolves against the source width (4000) -> 2000" do
    conn = call("/images/beach.jpg?twic=v1/resize=50p/output=jpeg")
    assert {2000, _} = dimensions(conn)
  end

  test "malformed chain is rejected before any source fetch" do
    opts = Keyword.put(@opts, :sources, path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginShouldNotFetch]})
    conn = call("/images/beach.jpg?twic=v1/zoom=2", opts)
    assert conn.status == 400
    refute_received :origin_fetch
  end
end
```

- [ ] **Step 3: Run to verify it fails, then passes**

Run: `mise exec -- mix test test/image_pipe/twic_pics_wire_conformance_test.exs`
Expected: PASS once Phases 1-3 are in place. The `170` / `85` / `2000` assertions prove runtime running-dimension resolution; the `zoom` case proves pre-fetch rejection.

- [ ] **Step 4: Commit**

```bash
git add test/support/image_pipe/twic_pics_wire_conformance_test test/image_pipe/twic_pics_wire_conformance_test.exs
git commit -m "test(twicpics): wire-level running-dimension + pre-fetch rejection"
```

### Task 4.2: Cover/focus, contain vs inside, output negotiation, cache reuse

**Files:**
- Modify: `test/image_pipe/twic_pics_wire_conformance_test.exs` (append)

- [ ] **Step 1: Append the tests**

```elixir
  defp average(%Plug.Conn{} = conn) do
    conn.resp_body
    |> Image.open!(access: :random, fail_on: :error)
    |> Image.average!()
  end

  test "focus anchor steers the cover crop (decoded pixels differ from centered baseline)" do
    centered = call("/images/beach.jpg?twic=v1/cover=200x200/output=jpeg")
    topleft = call("/images/beach.jpg?twic=v1/focus=top-left/cover=200x200/output=jpeg")

    assert dimensions(centered) == {200, 200}
    assert dimensions(topleft) == {200, 200}
    # Decoded-pixel signal (not raw bytes): a top-left crop of a photo averages
    # differently than a centered crop.
    refute average(centered) == average(topleft)
  end

  test "cover ratio crops to the target ratio without scaling" do
    conn = call("/images/beach.jpg?twic=v1/cover=16:9/output=jpeg")
    {w, h} = dimensions(conn)
    # beach.jpg is 4000x2667 (ratio 1.5 < 16:9); the largest 16:9 area is 4000x2250.
    assert_in_delta w / h, 16 / 9, 0.02
  end

  test "contain fits inside; inside letterboxes to exact dims with a transparent border" do
    contain = call("/images/beach.jpg?twic=v1/contain=200x200/output=png")
    inside = call("/images/beach.jpg?twic=v1/inside=200x200/output=png")

    {cw, ch} = dimensions(contain)
    assert cw == 200
    assert ch < 200

    assert dimensions(inside) == {200, 200}
    img = Image.open!(inside.resp_body, access: :random, fail_on: :error)
    assert Image.has_alpha?(img)
  end

  test "explicit output bypasses negotiation; auto sets Vary: Accept" do
    explicit = call("/images/beach.jpg?twic=v1/resize=100/output=avif")
    assert Plug.Conn.get_resp_header(explicit, "content-type") == ["image/avif"]

    auto =
      :get
      |> conn("/images/beach.jpg?twic=v1/resize=100/output=auto")
      |> Plug.Conn.put_req_header("accept", "image/webp")
      |> ImagePipe.Plug.call(ImagePipe.Plug.init(@opts))

    assert "accept" in Enum.flat_map(Plug.Conn.get_resp_header(auto, "vary"), &String.split(&1, ", "))
  end

  test "inside with a non-alpha output flattens (no error, exact dims)" do
    conn = call("/images/beach.jpg?twic=v1/inside=200x200/output=jpeg")
    assert conn.status == 200
    assert dimensions(conn) == {200, 200}
  end

  test "oversized chained upscale is rejected by the result limit after fetch" do
    # :max_result_pixels is a real top-level option (lib/image_pipe/request/options.ex:58)
    opts = Keyword.put(@opts, :max_result_pixels, 1_000_000)
    conn = call("/images/beach.jpg?twic=v1/resize=4s/resize=4s/output=jpeg", opts)
    assert conn.status >= 400
  end

  test "two semantically-equivalent requests reuse the same cache entry" do
    cache_root =
      Path.join(System.tmp_dir!(), "twicpics_wire_cache_#{System.unique_integer([:positive])}")

    File.rm_rf!(cache_root)
    File.mkdir_p!(cache_root)
    on_exit(fn -> File.rm_rf!(cache_root) end)

    opts =
      @opts
      |> Keyword.put(
        :sources,
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: {OriginImage, test_pid: self()}]}
      )
      |> Keyword.put(
        :cache,
        {ImagePipe.Cache.FileSystem,
         root: cache_root, path_prefix: "processed", max_body_bytes: 10_000_000, key_headers: [], key_cookies: []}
      )

    first = call("/images/beach.jpg?twic=v1/resize=200/output=jpeg", opts)
    assert first.status == 200
    assert_received :origin_fetch

    second = call("/images/beach.jpg?twic=v1/resize=200/output=jpeg", opts)
    assert second.status == 200
    assert second.resp_body == first.resp_body
    refute_received :origin_fetch
  end
```

Note: the `OriginImage` support plug already forwards `test_pid` and sends `:origin_fetch` (Task 4.1). `Image.has_alpha?/1` is the public predicate from the `image` library (a project dependency).

- [ ] **Step 2: Run the tests**

Run: `mise exec -- mix test test/image_pipe/twic_pics_wire_conformance_test.exs`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/twic_pics_wire_conformance_test.exs
git commit -m "test(twicpics): cover/focus, contain vs inside, output, result-limit"
```

### Task 4.3: Property test for running-dimension resolution

**Files:**
- Create: `test/image_pipe/transform/resize_relative_resolution_property_test.exs`

- [ ] **Step 1: Write the property test**

```elixir
defmodule ImagePipe.Transform.ResizeRelativeResolutionPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Transform.Operation.Resize

  property "percent width resolves to round(running_width * percent / 100)" do
    check all running <- integer(1..6000),
              percent <- integer(1..400) do
      op = %Resize{mode: :fit, width: {:percent, percent}, height: :auto, enlarge: true}
      result = Resize.resolve_dimensions(op, source_width: running, source_height: running)

      assert result.intermediate_width == max(1, round(running * percent / 100))
    end
  end
end
```

- [ ] **Step 2: Run it**

Run: `mise exec -- mix test test/image_pipe/transform/resize_relative_resolution_property_test.exs`
Expected: PASS. (Asserts at the resolver where the running length is supplied directly — not a fixture round-trip, so enlargement clamping does not confound it. `enlarge: true` keeps the `:fit` path from clamping to the synthetic source.)

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/transform/resize_relative_resolution_property_test.exs
git commit -m "test(transform): property — percent resize resolves against running width"
```

---

## Phase 5 — Support matrix + final gate

### Task 5.1: Flip implemented rows to ✅ and run the full gate

**Files:**
- Modify: `docs/twicpics_support_matrix.md`

- [ ] **Step 1: Update statuses**

In `docs/twicpics_support_matrix.md`, change the status of the now-implemented rows from `📋 Planned (v1)` to `✅ Supported`: the `?twic=v1/<chain>` envelope, ordered chaining, running-dimension relative units, path→source, `resize=W`, `resize=WxH`, `cover=WxH`, `cover=W:H`, `contain=WxH`, `inside=WxH` (keep `⚠️ Partial`), `crop=WxH`, `crop=WxH@XxY`, `focus=<anchor>`, `output=auto`, `output=avif|webp|jpeg|png`, `quality=1..100`, and the Length/Size/Crop-size/Ratio/Coordinates/Anchor parameter rows. Before flipping a row, confirm it exists; if any v1 surface element listed here has no row, add it (the matrix must carry a row for every TwicPics transformation and parameter). Note on the `crop` and `inside` rows that **v1 accepts pixel dimensions only** (relative units on crop/inside deferred), and on the Anchor/Coordinates rows that **coordinate focus is deferred — v1 focus is anchor-only**.

- [ ] **Step 2: Run the full Elixir gate**

Run: `mise run precommit`
Expected: PASS — `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all green.

- [ ] **Step 3: Commit**

```bash
git add docs/twicpics_support_matrix.md
git commit -m "docs(twicpics): mark v1 surface as supported in the matrix"
```

---

## Out of scope for this plan (separate follow-on plans)

- **Demo TwicPics mode.** The demo (`demo/src/processing-path.ts`, `demo-url-state.ts`, `App.svelte`, `dev/simple_server.ex`) is imgproxy-hardwired with no parser-mode abstraction. Adding a TwicPics mode is its own spec→plan cycle, gated by `mise run precommit:demo` (`vitest`, `tsgo`/`svelte-check`, `oxfmt`, `oxlint`, `vite build`).
- **Coordinate focus** (px/percent/scale focus points) — needs a runtime-resolved focal guide on the core, mirroring the resize relative-unit machinery.
- Deferred TwicPics surface per the matrix: arithmetic expressions, `-min`/`-max`, `zoom`/`flip`/`turn`, color chaining, `focus=auto` smart crop, `resize=W:H`/`inside=W:H`, static chain collapse.
