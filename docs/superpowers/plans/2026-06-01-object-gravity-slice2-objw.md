# Object Gravity Slice 2 (`objw` per-class weights) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add imgproxy `gravity:objw:%class:%weight:…` per-class object weighting, so a class weight measurably biases the content-aware crop's focal point.

**Architecture:** The detect guide is reshaped from `{:detect, spec}` to `{:detect, {spec, weights}}` (weights a sparse `%{optional(:default) => float, optional(String.t()) => float}` map; empty = uniform). The imgproxy parser emits a raw `{:objw, pairs}` gravity; the imgproxy plan builder is the sole canonicalizer (`all`→`:default`, drop rules; the spec is derived from the named classes, collapsing to `:all` only when `all` is present — see the design spec's 2026-06-01 filtering correction). The weighted centroid is extracted into a **pure module** `ImagePipe.Transform.Focal` (`pull = classWeight(label) · √area`) so it is unit-testable with exact focal coordinates — the executable crop delegates to it.

**Tech Stack:** Elixir, ExUnit + StreamData, Plug, the `image`/libvips stack, `:telemetry`.

**Spec:** `docs/superpowers/specs/2026-06-01-object-gravity-slice2-design.md`

**Testing strategy (important — revised after plan review):** The `√area` formula and the weight lever are pinned by **exact unit tests** on `ImagePipe.Transform.Focal.weighted_centroid/4` (a pure function over regions → `{:fp, x, y}`). Wire-level tests prove only *coarse* end-to-end integration (a request renders, and a weighted crop's body differs from the uniform one). This avoids the trap that, on the 4000×2667 `beach.jpg` fixture, small detector boxes make every centroid clamp to the same crop window — so wire byte-comparisons can't isolate the formula. Wire detector boxes are therefore sized as large fractions of the fixture, and the implementer must confirm each wire test actually fails-then-passes (adjusting box coordinates if a crop clamps and masks the difference).

**Sequencing rationale:** Task 1 reshapes the guide *behavior-preservingly* (extract `Focal` with `pull = weight · area`; empty weights ⇒ today's area centroid) so the suite stays green. Task 2 flips `Focal` to `√area` and updates its exact unit assertions. Tasks 3–4 add `objw` parsing + canonicalization. Task 5 adds the weight unit test, telemetry, and the coarse wire pixel proof. Task 6 covers cache identity/reuse. Task 7 does demo + docs.

**Conventions:**
- Run everything through mise: `mise exec -- mix test …`, `mise exec -- mix format`, etc.
- Weights are **floats** (the parser uses `parse_positive_float/1`), so `objw:all:2:face:3` yields `%{default: 2.0, "face" => 3.0}`. Tests assert floats.
- Gate before finishing broad changes: `mise run precommit`.

---

## File Structure

**Created (production):**
- `lib/image_pipe/transform/focal.ex` — pure weighted-centroid (`weighted_centroid/4`). Lives in the `transform` boundary (same as `crop.ex`), so no Boundary export is needed; `crop.ex` calls it intra-boundary.

**Modified (production):**
- `lib/image_pipe/plan/operation/crop_guided.ex`, `resize.ex` — guide typespec (+ `weights` type).
- `lib/image_pipe/plan/operation.ex` — `smart_guide/1` validator.
- `lib/image_pipe/plan.ex` — `detect_classes/1`.
- `lib/image_pipe/plan/key_data.ex` — `guide_data/1`.
- `lib/image_pipe/transform/plan_executor.ex` — `tagged_executable_gravity/1`.
- `lib/image_pipe/transform/operation/crop.ex` — guide typespec, `execute/2`, `detect_crop`, `detect_crop_with_module`, `run_detect`, `face_assist_crop`; delete `focal_from_regions/3`, delegate to `Focal`.
- `lib/image_pipe/parser/imgproxy/option_grammar.ex` — `objw` grammar + `parse_object_weights`.
- `lib/image_pipe/parser/imgproxy/plan_builder.ex` — `object_detect_guide/2`, `canonical_weights/1`, `{:objw, …}` clauses.
- `lib/image_pipe/parser/imgproxy/crop_request.ex` — `gravity()` typespec.

**Created (tests):**
- `test/image_pipe/transform/focal_test.exs` — exact centroid unit tests.

**Modified (tests):** `test/image_pipe/transform/crop_operation_test.exs` (10 old-shape sites), `test/parser/imgproxy/option_grammar_test.exs`, `test/parser/imgproxy/plan_builder_test.exs` (all `{:detect, …}` assertions), `test/image_pipe/plan_test.exs`, `test/image_pipe/plan/operation_key_data_test.exs`, `test/image_pipe/cache/key_test.exs`, `test/image_pipe/imgproxy_wire_conformance_test.exs`, and the detect-span telemetry test.

**Modified (docs/demo):** `docs/content-aware-gravity.md`, `docs/imgproxy_support_matrix.md`, `demo/`.

---

## Task 1: Reshape the detect guide to `{:detect, {spec, weights}}` (behavior-preserving)

Extract the centroid into `ImagePipe.Transform.Focal` (still `pull = classWeight · area`, so uniform = today), reshape every guide producer/validator/consumer, and update every old-shape test. One commit; suite stays green because empty weights ⇒ weight `1.0` ⇒ identical `area` centroid.

**Files:**
- Create: `lib/image_pipe/transform/focal.ex`, `test/image_pipe/transform/focal_test.exs`
- Modify: `lib/image_pipe/plan/operation/crop_guided.ex`, `resize.ex`, `plan/operation.ex`, `plan.ex`, `plan/key_data.ex`, `transform/plan_executor.ex`, `transform/operation/crop.ex`, `parser/imgproxy/plan_builder.ex`
- Test (modify): `test/image_pipe/transform/crop_operation_test.exs`, `test/parser/imgproxy/plan_builder_test.exs`, `test/image_pipe/plan_test.exs`, `test/image_pipe/plan/operation_key_data_test.exs`, `test/image_pipe/cache/key_test.exs`

- [ ] **Step 1: Write the `Focal` unit test (area-weighted, drives the new module)**

Create `test/image_pipe/transform/focal_test.exs`:

```elixir
defmodule ImagePipe.Transform.FocalTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Focal

  # Scene in a 100×100 image: a tall "person" box and a small "face" box high
  # inside it, sharing center x = 50. Vertical centroid is the discriminating axis.
  defp scene do
    [
      %{label: "person", score: 0.9, box: {30, 20, 40, 70}},
      %{label: "face", score: 0.9, box: {40, 20, 20, 20}}
    ]
  end

  test "uniform area-weighted centroid (empty weights)" do
    assert {:ok, {:fp, fx, fy}} = Focal.weighted_centroid(scene(), 100, 100, %{})
    assert_in_delta fx, 0.5, 0.0001
    # area: (2800·55 + 400·30) / 3200 = 51.875
    assert_in_delta fy, 0.51875, 0.0001
  end

  test "a uniform default scalar does not move the centroid (cancels)" do
    {:ok, fp_a} = Focal.weighted_centroid(scene(), 100, 100, %{})
    {:ok, fp_b} = Focal.weighted_centroid(scene(), 100, 100, %{default: 2.0})
    assert fp_a == fp_b
  end

  test "returns :none when no box falls fully inside the image" do
    assert Focal.weighted_centroid([%{label: "x", box: {200, 200, 10, 10}}], 100, 100, %{}) == :none
  end

  test "a missing label resolves to the default/1.0 weight" do
    regions = [%{box: {0, 0, 10, 10}}, %{box: {90, 90, 10, 10}}]
    assert {:ok, {:fp, fx, fy}} = Focal.weighted_centroid(regions, 100, 100, %{})
    assert_in_delta fx, 0.5, 0.0001
    assert_in_delta fy, 0.5, 0.0001
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/focal_test.exs`
Expected: FAIL — `ImagePipe.Transform.Focal` does not exist.

- [ ] **Step 3: Create the `Focal` module (area term for now)**

Create `lib/image_pipe/transform/focal.ex`:

```elixir
defmodule ImagePipe.Transform.Focal do
  @moduledoc false
  # Pure weighted centroid of detected regions for object gravity. Each region
  # pulls the focal point toward its box center, weighted by `classWeight(label) ·
  # area_term(area)`. Task 2 swaps `area_term` from `area` to `√area`; the class
  # weight is the Slice 2 addition. Kept pure (no image/State) so the formula is
  # unit-testable with exact coordinates.

  @type region :: %{
          optional(:label) => String.t() | nil,
          optional(any()) => any(),
          box: {number(), number(), number(), number()}
        }
  @type weights :: %{optional(:default) => number(), optional(String.t()) => number()}

  @spec weighted_centroid([region()], number(), number(), weights()) ::
          {:ok, {:fp, float(), float()}} | :none
  def weighted_centroid(regions, image_width, image_height, weights) do
    in_image =
      Enum.filter(regions, fn %{box: {x, y, w, h}} ->
        w > 0 and h > 0 and x >= 0 and y >= 0 and x + w <= image_width and y + h <= image_height
      end)

    case in_image do
      [] ->
        :none

      boxes ->
        total = Enum.reduce(boxes, 0.0, fn region, acc -> acc + region_pull(region, weights) end)

        {sx, sy} =
          Enum.reduce(boxes, {0.0, 0.0}, fn %{box: {x, y, w, h}} = region, {ax, ay} ->
            pull = region_pull(region, weights)
            {ax + pull * (x + w / 2), ay + pull * (y + h / 2)}
          end)

        {:ok, {:fp, clamp_unit(sx / total / image_width), clamp_unit(sy / total / image_height)}}
    end
  end

  defp region_pull(%{box: {_x, _y, w, h}} = region, weights) do
    class_weight(Map.get(region, :label), weights) * area_term(w, h)
  end

  # Task 2 changes this to `:math.sqrt(w * h)`.
  defp area_term(w, h), do: w * h

  defp class_weight(label, weights) do
    Map.get(weights, label, Map.get(weights, :default, 1.0))
  end

  defp clamp_unit(value) when value < 0.0, do: 0.0
  defp clamp_unit(value) when value > 1.0, do: 1.0
  defp clamp_unit(value), do: value
end
```

- [ ] **Step 4: Run the unit test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/transform/focal_test.exs`
Expected: PASS.

- [ ] **Step 5: Delegate from `crop.ex` to `Focal` and thread weights**

In `lib/image_pipe/transform/operation/crop.ex`:

Add the alias near the top (with the other aliases):

```elixir
  alias ImagePipe.Transform.Focal
```

Update the `gravity` typespec's two detect lines:

```elixir
            | {:detect, {:all, %{optional(:default) => number(), optional(String.t()) => number()}}}
            | {:detect,
               {[String.t()], %{optional(:default) => number(), optional(String.t()) => number()}}}
```

Update the detect `execute/2` clause:

```elixir
  def execute(%__MODULE__{gravity: {:detect, {spec, weights}}} = params, %State{} = state) do
    detect_crop(params, state, spec, weights)
  end
```

Replace `detect_crop/3` and `detect_crop_with_module/5`:

```elixir
  defp detect_crop(%__MODULE__{} = params, %State{} = state, spec, weights) do
    {module, dopts} = normalize_detector(state.detector)

    if is_nil(module) do
      emit_detect_skipped(spec, state.telemetry_opts)
      smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    else
      detect_crop_with_module(params, state, module, dopts, spec, weights)
    end
  end

  defp detect_crop_with_module(%__MODULE__{} = params, %State{} = state, module, dopts, spec, weights) do
    with {:ok, [_ | _] = regions} <-
           run_detect(module, dopts, state.image, spec, weights, state.telemetry_opts),
         {:ok, focal} <-
           Focal.weighted_centroid(regions, image_width(state), image_height(state), weights) do
      execute(%{params | gravity: focal}, state)
    else
      _ -> smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    end
  end
```

Replace `run_detect/5` with `/6` (weights on the span; detector still gets only `:classes`):

```elixir
  defp run_detect(module, opts, image, classes, weights, telemetry_opts) do
    Telemetry.span(telemetry_opts, [:transform, :detect], %{classes: classes, weights: weights}, fn ->
      detect_opts =
        opts |> Keyword.put(:classes, classes) |> Keyword.put(:telemetry_opts, telemetry_opts)

      result = validate_detect_result(module.detect(image, detect_opts))
      {result, %{regions: region_count(result), result: detect_reason(result)}}
    end)
  end
```

Update `face_assist_crop` to pass uniform weights (`%{}`) and the `/6` `run_detect`, delegating to `Focal`:

```elixir
  defp face_assist_crop(%__MODULE__{} = params, %State{} = state, module, dopts) do
    with {:ok, [_ | _] = regions} <-
           run_detect(module, dopts, state.image, ["face"], %{}, state.telemetry_opts),
         {:ok, {:fp, fx, fy}} <-
           Focal.weighted_centroid(regions, image_width(state), image_height(state), %{}),
         {:ok, {ax, ay}} <- attention_point(params, state) do
      blended = {blend_axis(ax, fx), blend_axis(ay, fy)}
      emit_blend(state.telemetry_opts, {ax, ay}, {fx, fy}, blended)
      {bx, by} = blended
      execute(%{params | gravity: {:fp, bx, by}}, state)
    else
      _ -> smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    end
  end
```

Delete the old private `focal_from_regions/3` from `crop.ex` (now in `Focal`). Keep `clamp_unit/1` in `crop.ex` — `blend_axis/2` still uses it.

- [ ] **Step 6: Add the `weights` typespec and update guide types**

In `lib/image_pipe/plan/operation/crop_guided.ex`, add the type and replace the two `{:detect, …}` lines:

```elixir
  @type weights :: %{optional(:default) => number(), optional(String.t()) => number()}
```
```elixir
          | {:detect, {:all, weights()}}
          | {:detect, {nonempty_list(String.t()), weights()}}
```

Mirror in `lib/image_pipe/plan/operation/resize.ex` (add `@type weights` and the same two guide lines).

- [ ] **Step 7: Teach `smart_guide/1` the new shape (shape-only, trust the producer)**

In `lib/image_pipe/plan/operation.ex`, replace the two `{:detect, …}` clauses. Validate shape only — NOT weight values (the parser/canonicalizer is the in-repo producer):

```elixir
  defp smart_guide({:detect, {:all, weights}} = guide) when is_map(weights), do: {:ok, guide}

  defp smart_guide({:detect, {classes, weights}} = guide)
       when is_list(classes) and classes != [] and is_map(weights) do
    if Enum.all?(classes, &is_binary/1) do
      {:ok, guide}
    else
      {:error, :guide}
    end
  end
```

- [ ] **Step 8: Emit the new shape from the plan builder**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, replace `object_detect_guide/1`:

```elixir
  # Maps imgproxy object gravity to a product-neutral detect guide. Bare `obj`
  # (empty classes) or `all` anywhere collapses spec to :all; otherwise the class
  # list is carried through. Weights are empty for `obj`; `objw` supplies a
  # canonical map via the /2 form. Shared by resize_guide (fill) and
  # tagged_gravity (crop) so the paths cannot diverge.
  defp object_detect_guide(classes), do: object_detect_guide(classes, %{})

  defp object_detect_guide(classes, weights) when is_map(weights) do
    spec = if classes == [] or "all" in classes, do: :all, else: classes
    {:detect, {spec, weights}}
  end
```

- [ ] **Step 9: Update `detect_classes/1`, the executor, and key_data**

`lib/image_pipe/plan.ex` — replace the two `case` clauses in the reduce:

```elixir
        {:detect, {:all, _weights}} -> {:halt, :all}
        {:detect, {classes, _weights}} when is_list(classes) -> {:cont, classes ++ acc}
```

`lib/image_pipe/transform/plan_executor.ex` — replace the detect clause:

```elixir
  defp tagged_executable_gravity({:detect, {spec, weights}}), do: {:detect, {spec, weights}}
```

`lib/image_pipe/plan/key_data.ex` — replace the two `{:detect, …}` clauses (weights ride as a **map** so `Cache.Key.canonicalize/1` orders them):

```elixir
  defp guide_data({:detect, {:all, weights}}) when is_map(weights),
    do: [type: :detect, classes: :all, weights: weights]

  defp guide_data({:detect, {classes, weights}}) when is_list(classes) and is_map(weights),
    do: [type: :detect, classes: Enum.sort(classes), weights: weights]
```

- [ ] **Step 10: Update ALL old-shape tests**

**`test/image_pipe/transform/crop_operation_test.exs`** — this file builds `%Crop{gravity: {:detect, ["face"]}}` structs directly (~10 sites) and asserts `{:ok, …}` + detect-span telemetry. Replace **every** `gravity: {:detect, ["face"]}` with `gravity: {:detect, {["face"], %{}}}`. (Grep the file for `{:detect,` to find all of them.) Behavior is unchanged (empty weights ⇒ area centroid), so the `{:ok, …}` and telemetry assertions still hold.

**`test/parser/imgproxy/plan_builder_test.exs`** — update **every** `{:detect, …}` assertion (there are ~11, not just the headline three). Grep the file for `{:detect,` and rewrite each:
- `{:detect, ["face"]}` → `{:detect, {["face"], %{}}}`
- `{:detect, :all}` → `{:detect, {:all, %{}}}`
- multi-class, numeric-token, "all among classes", and the dialect-leak `expected_guide` list — all wrapped the same way.

**`test/image_pipe/plan_test.exs`** — the detect cases:

```elixir
    assert Plan.detect_classes(plan_with_guide({:detect, {["face"], %{}}})) == ["face"]
    assert Plan.detect_classes(plan_with_guide({:detect, {["dog", "car", "dog"], %{}}})) == ["car", "dog"]
    assert Plan.detect_classes(plan_with_guide({:detect, {:all, %{}}})) == :all
```

**`test/image_pipe/plan/operation_key_data_test.exs`** — wrap every `guide: {:detect, classes}` as `{:detect, {classes, %{}}}` (and shuffled variants), and update the `:all` expectation:

```elixir
    test "detect :all guide encodes as classes: :all" do
      data =
        KeyData.data(%CropGuided{width: {:px, 100}, height: {:px, 100}, guide: {:detect, {:all, %{}}}})

      assert Keyword.fetch!(data, :guide) == [type: :detect, classes: :all, weights: %{}]
    end
```

**`test/image_pipe/cache/key_test.exs`** — the `detect_crop_operation/2` helper:

```elixir
             Operation.crop_guided(
               tagged_dimension(width),
               tagged_dimension(height),
               {:detect, {["face"], %{}}}
             )
```

- [ ] **Step 11: Run the full suite**

Run: `mise exec -- mix test`
Expected: PASS. Pixel results unchanged (empty weights ⇒ `1.0 · area` ⇒ today's centroid). If anything fails, it is a missed old-shape `{:detect, …}` literal — grep `test/` and `lib/` for `{:detect,` and fix.

- [ ] **Step 12: Format, compile clean, commit**

Run: `mise exec -- mix format && mise exec -- mix compile --warnings-as-errors`

```bash
git add lib test
git commit -m "refactor: reshape detect guide to {:detect, {spec, weights}}; extract Focal centroid"
```

---

## Task 2: Switch the weighted centroid to `weight·√area`

Flip `Focal.area_term` from `w*h` to `√(w*h)` and update the exact unit assertions. Single-box detections don't move (centroid = box center under any area term), so Slice 1 single-box wire/crop tests stay green.

**Files:**
- Modify: `lib/image_pipe/transform/focal.ex`
- Test: `test/image_pipe/transform/focal_test.exs`

- [ ] **Step 1: Update the unit test to the √area expectation (failing)**

In `test/image_pipe/transform/focal_test.exs`, change the uniform-centroid expectation. With √area, person √area = √2800 ≈ 52.915, face √area = √400 = 20:

```elixir
  test "uniform √area-weighted centroid (empty weights)" do
    assert {:ok, {:fp, fx, fy}} = Focal.weighted_centroid(scene(), 100, 100, %{})
    assert_in_delta fx, 0.5, 0.0001
    # √area: (52.915·55 + 20·30) / 72.915 ≈ 48.14
    assert_in_delta fy, 0.4814, 0.0005
  end
```

(The "default scalar cancels", ":none", and "missing label" tests are formula-independent and stay.)

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/transform/focal_test.exs`
Expected: FAIL — current `area_term` gives 0.51875, not 0.4814.

- [ ] **Step 3: Switch to √area**

In `lib/image_pipe/transform/focal.ex`:

```elixir
  # √area tracks the box's linear size, so a class weight is a responsive lever
  # (a face boost actually moves the crop) while a dominant object still wins.
  # See the Slice 2 design doc for the rationale.
  defp area_term(w, h), do: :math.sqrt(w * h)
```

- [ ] **Step 4: Run the unit test and full suite**

Run: `mise exec -- mix test test/image_pipe/transform/focal_test.exs`
Expected: PASS.

Run: `mise exec -- mix test`
Expected: PASS. If a pre-existing **multi-box** focal/pixel assertion fails, it is the intended `√area` shift — update its expected value and note it in the commit. (All Slice 1 detector fixtures return a single box, so none should move; confirm.)

- [ ] **Step 5: Commit**

```bash
git add lib test
git commit -m "feat: weight object-gravity centroid by √area (responsive class-weight lever)"
```

---

## Task 3: Parse `objw` grammar

Variable-arity, so **not** an `@special_specs` entry. Add `objw` to the three bespoke entry points; emit raw `{:objw, [{class, weight_float}]}`; reject malformed input here.

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex`, `crop_request.ex`
- Test: `test/parser/imgproxy/option_grammar_test.exs`

- [ ] **Step 1: Write failing parser tests**

Add to `test/parser/imgproxy/option_grammar_test.exs`:

```elixir
  test "objw gravity parses class/weight pairs (floats)" do
    assert OptionGrammar.parse("g:objw:all:2:face:3") ==
             {:ok,
              {:pipeline,
               [
                 gravity: {:objw, [{"all", 2.0}, {"face", 3.0}]},
                 gravity_x_offset: {:pixels, 0.0},
                 gravity_y_offset: {:pixels, 0.0}
               ]}}
  end

  test "objw gravity accepts decimal weights" do
    assert {:ok, {:pipeline, opts}} = OptionGrammar.parse("g:objw:face:2.5")
    assert opts[:gravity] == {:objw, [{"face", 2.5}]}
  end

  test "crop objw gravity parses class/weight pairs" do
    assert {:ok, {:pipeline, [crop: %CropRequest{gravity: gravity}]}} =
             OptionGrammar.parse("c:100:100:objw:all:1:face:3")

    assert gravity == {:objw, [{"all", 1.0}, {"face", 3.0}]}
  end

  test "objw gravity rejects non-positive, odd-arity, empty-class, and bare forms" do
    assert {:error, _} = OptionGrammar.parse("g:objw:face:0")
    assert {:error, _} = OptionGrammar.parse("g:objw:face:-2")
    assert {:error, _} = OptionGrammar.parse("g:objw:all:2:face")
    assert {:error, _} = OptionGrammar.parse("g:objw::3")
    assert {:error, _} = OptionGrammar.parse("g:objw")
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs -k objw`
Expected: FAIL — `objw` falls through to `{:error, {:invalid_option_segment, _}}`.

- [ ] **Step 3: Add the `objw` gravity clause + pair parser**

In `lib/image_pipe/parser/imgproxy/option_grammar.ex`, add right after the `parse_gravity(["obj" | classes], …)` clause. The `pairs != []` guard makes bare `objw` fall through to the catch-all reject:

```elixir
  defp parse_gravity(["objw" | pairs], segment) when pairs != [] do
    with {:ok, weights} <- parse_object_weights(pairs, segment) do
      {:ok,
       [
         gravity: {:objw, weights},
         gravity_x_offset: {:pixels, 0.0},
         gravity_y_offset: {:pixels, 0.0}
       ]}
    end
  end
```

Add the pair parser near `parse_crop_gravity`:

```elixir
  # Parses imgproxy objw class/weight pairs into [{class_string, weight_float}].
  # Positional: class then weight, repeating. Rejects odd arity, empty class
  # tokens, and non-positive/non-numeric weights at the parser boundary.
  defp parse_object_weights([], segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_object_weights(tokens, segment), do: parse_object_weights(tokens, segment, [])

  defp parse_object_weights([], _segment, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_object_weights([class, weight | rest], segment, acc) when class != "" do
    with {:ok, weight} <- parse_positive_float(weight) do
      parse_object_weights(rest, segment, [{class, weight} | acc])
    end
  end

  defp parse_object_weights(_tokens, segment, _acc),
    do: {:error, {:invalid_option_segment, segment}}
```

- [ ] **Step 4: Add the crop-path clauses**

Add an `objw` clause to `parse_crop_gravity` (after the `obj` clause):

```elixir
  defp parse_crop_gravity(["objw" | pairs]) do
    with {:ok, weights} <- parse_object_weights(pairs, "crop") do
      {:ok, {:objw, weights}}
    end
  end
```

Add the inline `parse_crop` clause. **Placement matters:** it must sit before the generic 5-element `parse_crop([w, h, gravity, x_offset, y_offset], …)` clause (~line 765) so `c:W:H:objw:face:3` (5 tokens) isn't shadowed. Put it directly after the existing `parse_crop([w, h, "obj" | classes], …)` clause (~line 745):

```elixir
  defp parse_crop([width, height, "objw" | pairs], _segment)
       when width != "" and height != "" do
    with {:ok, width} <- parse_crop_dimension(width),
         {:ok, height} <- parse_crop_dimension(height),
         {:ok, gravity} <- parse_crop_gravity(["objw" | pairs]) do
      {:ok, [crop: %CropRequest{width: width, height: height, gravity: gravity}]}
    end
  end
```

- [ ] **Step 5: Extend the `CropRequest.gravity()` typespec**

In `lib/image_pipe/parser/imgproxy/crop_request.ex` (it currently omits even `:obj`):

```elixir
  @type gravity() ::
          {:anchor, :left | :center | :right, :top | :center | :bottom}
          | {:fp, float(), float()}
          | {:obj, [String.t()]}
          | {:objw, [{String.t(), float()}]}
          | :sm
          | nil
```

- [ ] **Step 6: Run parser tests + full suite**

Run: `mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs && mise exec -- mix test`
Expected: PASS. (No production path feeds `{:objw, …}` into the planner yet — only the new parser unit tests assert the raw output, which doesn't build a plan — so the suite is green before Task 4.)

- [ ] **Step 7: Commit**

```bash
git add lib test
git commit -m "feat: parse imgproxy objw class/weight gravity grammar"
```

---

## Task 4: Canonicalize `{:objw, …}` into the detect guide (sole canonicalizer)

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex`
- Test: `test/parser/imgproxy/plan_builder_test.exs`

- [ ] **Step 1: Write failing plan-builder tests**

Add to `test/parser/imgproxy/plan_builder_test.exs`:

```elixir
  test "objw maps to detect :all with a canonical weights map" do
    assert objw_guide([{"all", 1.0}, {"face", 3.0}]) == {:detect, {:all, %{"face" => 3.0}}}
  end

  test "objw all-baseline above 1 is carried; a class equal to default is dropped" do
    assert objw_guide([{"all", 3.0}, {"car", 3.0}]) == {:detect, {:all, %{default: 3.0}}}
  end

  test "objw all-baseline with a below-default class" do
    assert objw_guide([{"all", 3.0}, {"car", 1.0}]) == {:detect, {:all, %{default: 3.0, "car" => 1.0}}}
  end

  test "objw canonicalizes equivalent URLs to the same guide" do
    assert objw_guide([{"face", 3.0}]) == objw_guide([{"all", 1.0}, {"face", 3.0}])
  end

  test "objw uniform weights canonicalize to an empty map" do
    assert objw_guide([{"all", 1.0}, {"face", 1.0}]) == {:detect, {:all, %{}}}
  end

  test "objw maps identically through the crop path (no fill/crop divergence)" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]}} =
             plan_pipeline(
               crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: {:objw, [{"all", 2.0}, {"face", 3.0}]}
               }
             )

    assert crop.guide == {:detect, {:all, %{default: 2.0, "face" => 3.0}}}
  end
```

Add the helper (fill path) near the other test helpers:

```elixir
  defp objw_guide(pairs) do
    {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}]}} =
      plan_pipeline(
        resizing_type: :fill,
        width: {:pixels, 100},
        height: {:pixels, 100},
        gravity: {:objw, pairs}
      )

    resize.guide
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/parser/imgproxy/plan_builder_test.exs -k objw`
Expected: FAIL — no `{:objw, …}` clause.

- [ ] **Step 3: Add `{:objw, …}` clauses + the canonicalizer**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, add next to the `{:obj, …}` clauses in **both** `resize_guide` and `tagged_gravity`:

```elixir
  defp resize_guide({:objw, pairs}, _face_assist),
    do: {:ok, object_detect_guide([], canonical_weights(pairs))}
```
```elixir
  defp tagged_gravity({:objw, pairs}, _face_assist),
    do: {:ok, object_detect_guide([], canonical_weights(pairs))}
```

(Passing `classes: []` makes `object_detect_guide/2` collapse `spec` to `:all` — imgproxy's "objw weights over everything" semantics.)

Add `canonical_weights/1` near `object_detect_guide/2`. This is the **sole** canonicalization site, implementing the spec's fixed order: `all`→`:default`; drop class entries equal to the effective default; drop `:default` iff `1.0`:

```elixir
  # Canonicalizes raw objw pairs into the sparse plan weights map. `all` →
  # :default; later pairs win on duplicate keys. Then the fixed-point drop rules
  # (effective default = :default or 1.0): drop class entries equal to it, then
  # drop :default when it is 1.0. The only place objw weights are canonicalized.
  defp canonical_weights(pairs) do
    raw =
      Enum.reduce(pairs, %{}, fn {class, weight}, acc ->
        key = if class == "all", do: :default, else: class
        Map.put(acc, key, weight)
      end)

    eff = Map.get(raw, :default, 1.0)

    raw
    |> Enum.reject(fn {key, weight} -> key != :default and weight == eff end)
    |> Map.new()
    |> drop_default_one()
  end

  defp drop_default_one(%{default: 1.0} = weights), do: Map.delete(weights, :default)
  defp drop_default_one(weights), do: weights
```

- [ ] **Step 4: Run tests + full suite**

Run: `mise exec -- mix test test/parser/imgproxy/plan_builder_test.exs && mise exec -- mix test`
Expected: PASS.

- [ ] **Step 5: Add canonicalization property tests (order-independent + idempotent)**

In `test/parser/imgproxy/plan_builder_test.exs` (the file already `use ExUnitProperties`; `member_of`/`uniq_list_of`/`list_of` come with it — mirror `operation_key_data_test.exs` usage):

```elixir
  property "objw canonicalization is order-independent" do
    check all classes <- uniq_list_of(member_of(["face", "car", "dog", "person"]), min_length: 1, max_length: 4),
              weights <- list_of(member_of([1.0, 2.0, 3.0]), length: length(classes)),
              default <- member_of([1.0, 2.0, 3.0]) do
      pairs = [{"all", default} | Enum.zip(classes, weights)]
      assert objw_guide(pairs) == objw_guide(Enum.shuffle(pairs))
    end
  end

  property "objw canonicalization is idempotent (re-feeding the canonical map changes nothing)" do
    check all classes <- uniq_list_of(member_of(["face", "car", "dog"]), min_length: 1, max_length: 3),
              weights <- list_of(member_of([1.0, 2.0]), length: length(classes)),
              default <- member_of([1.0, 2.0]) do
      {:detect, {:all, map}} = objw_guide([{"all", default} | Enum.zip(classes, weights)])
      # Rebuild pairs from the canonical map (default → "all") and re-canonicalize.
      repairs =
        Enum.map(map, fn
          {:default, w} -> {"all", w}
          {class, w} -> {class, w}
        end)

      reguide = if repairs == [], do: objw_guide([{"all", 1.0}]), else: objw_guide(repairs)
      assert reguide == {:detect, {:all, map}}
    end
  end
```

- [ ] **Step 6: Run and commit**

Run: `mise exec -- mix test test/parser/imgproxy/plan_builder_test.exs`
Expected: PASS.

```bash
git add lib test
git commit -m "feat: canonicalize objw weights into the detect plan guide"
```

---

## Task 5: Telemetry weights, weight unit proof, and coarse wire integration

**Files:**
- Test: `test/image_pipe/transform/focal_test.exs` (weight lever, exact)
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs` (coarse integration)
- Test: the existing detect-span telemetry test (search for `[:image_pipe, :transform, :detect, :stop]`)

- [ ] **Step 1: Unit-test the weight lever (exact, robust)**

In `test/image_pipe/transform/focal_test.exs`, add (with √area, the face at y=30 is pulled toward by boosting it):

```elixir
  test "a class weight pulls the centroid toward that class" do
    {:ok, {:fp, _, fy_uniform}} = Focal.weighted_centroid(scene(), 100, 100, %{})
    {:ok, {:fp, _, fy_boost}} = Focal.weighted_centroid(scene(), 100, 100, %{"face" => 3.0})

    # face center y = 30 (above the person centroid), so a face boost lowers fy.
    assert fy_boost < fy_uniform
    # √area: (52.915·55 + 3·20·30) / (52.915 + 60) ≈ 41.72
    assert_in_delta fy_boost, 0.4172, 0.0005
  end
```

Run: `mise exec -- mix test test/image_pipe/transform/focal_test.exs`
Expected: PASS (this is the precise, deterministic proof the weight is a working lever — independent of image fixtures).

- [ ] **Step 2: Add a fixture-scaled multi-box detector for coarse wire checks**

In `test/image_pipe/imgproxy_wire_conformance_test.exs`, after `CornerObjectDetector`. **Boxes are sized for the 4000×2667 `beach.jpg` fixture** so the centroid lands in different fill-crop windows (a `rs:fill:50:50` 1:1 crop slides horizontally in x∈[0,1333]; center x must land in (1333, 2667) to move). The big box centers x≈2400, the small box x≈1600:

```elixir
  # Slice 2: a large "person" box and a small "face" box, class-aware so obj:person
  # / obj:face filter to one box. Sized as large fractions of beach.jpg (4000×2667)
  # so the fill-crop window actually moves between weightings.
  defmodule WeightedSceneDetector do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @boxes [
      %{label: "person", score: 0.95, box: {2000, 800, 800, 1000}},
      %{label: "face", score: 0.95, box: {1400, 600, 400, 400}}
    ]

    @impl true
    def supported_classes(_), do: ["face", "person"]

    @impl true
    def available?(opts), do: Keyword.get(opts, :available?, true)

    @impl true
    def identity(_), do: {__MODULE__, :v1}

    @impl true
    def detect(_image, opts) do
      case Keyword.get(opts, :classes, :all) do
        :all -> {:ok, @boxes}
        classes -> {:ok, Enum.filter(@boxes, &(&1.label in List.wrap(classes)))}
      end
    end
  end
```

(Note: this is a purpose-built deterministic detector rather than `ImagePipe.Test.FakeDetector`, because the wire proof needs **class-aware** results — `FakeDetector` returns one static `:result` and can't filter `obj:person` vs `obj:face`.)

- [ ] **Step 3: Add coarse wire tests (integration, not formula isolation)**

```elixir
  # Slice 2: a face weight measurably changes the crop end-to-end. Exact focal
  # math is pinned in FocalTest; here we only prove the weight reaches pixels.
  test "objw face weight changes the rendered crop vs uniform" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)

    uniform = call_imgproxy("/_/rs:fill:50:50/g:obj:all/f:jpeg/plain/images/beach.jpg", opts)
    boosted = call_imgproxy("/_/rs:fill:50:50/g:objw:all:1:face:8/f:jpeg/plain/images/beach.jpg", opts)

    assert uniform.status == 200
    assert boosted.status == 200
    assert dimensions(boosted) == {50, 50}
    refute boosted.resp_body == uniform.resp_body
  end

  # Slice 2: uniform-weight objw canonicalizes to obj:all (the weight scalar
  # cancels in the centroid), so it renders identically. (Cache-key identity is a
  # separate question, covered in the cache task — not asserted here.)
  test "objw with all-equal weights renders identically to obj:all" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)

    objw = call_imgproxy("/_/rs:fill:50:50/g:objw:all:2/f:jpeg/plain/images/beach.jpg", opts)
    obj = call_imgproxy("/_/rs:fill:50:50/g:obj:all/f:jpeg/plain/images/beach.jpg", opts)

    assert objw.resp_body == obj.resp_body
  end

  # Slice 2: the c:W:H:objw crop form reaches the crop path and applies the weight.
  test "c:W:H:objw crop form applies the weight" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)

    weighted = call_imgproxy("/_/c:2000:2000:objw:all:1:face:8/f:jpeg/plain/images/beach.jpg", opts)
    uniform = call_imgproxy("/_/c:2000:2000:obj:all/f:jpeg/plain/images/beach.jpg", opts)

    assert weighted.status == 200
    refute weighted.resp_body == uniform.resp_body
  end

  # Slice 2: no-geometry objw returns 200.
  test "no-geometry g:objw returns 200 without a resize or crop" do
    opts = Keyword.merge(@default_opts, detector: WeightedSceneDetector)
    conn = call_imgproxy("/_/g:objw:all:1:face:3/plain/images/beach.jpg", opts)
    assert conn.status == 200
  end
```

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs -k objw`
Expected: PASS. **If `refute … ==` fails** (crop windows clamped to the same region), the box coordinates aren't separating the centroids — widen the box positions (push `person` center toward x≈2400 and `face` toward x≈1500, both within the movable (1333, 2667) band) until the bodies differ, then re-run. This empirical check is why the precise proof lives in `FocalTest`.

- [ ] **Step 4: Assert weights ride the detect span (telemetry)**

Find the existing detect-span test (it attaches `[:image_pipe, :transform, :detect, :stop]` and asserts on `metadata.classes`; see `test/image_pipe/transform/crop_operation_test.exs`). `Telemetry.span` merges start metadata into the `:stop` event and only drops `nil` values, so `weights` survives. Add, mirroring that file's exact handler pattern:

```elixir
  test "the detect span carries the resolved weights" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:image_pipe, :transform, :detect, :stop]])

    state = %State{
      image: image,
      detector: {FakeDetector, result: {:ok, [%{label: "face", score: 0.9, box: {10, 10, 30, 30}}]}}
    }

    {:ok, _} = Crop.execute(%Crop{width: 50, height: 50, gravity: {:detect, {:all, %{"face" => 3.0}}}}, state)

    assert_receive {[:image_pipe, :transform, :detect, :stop], ^ref, %{duration: _}, metadata}
    assert metadata.classes == :all
    assert metadata.weights == %{"face" => 3.0}
  end
```

(Use the file's existing `image`/`State`/`Crop`/`FakeDetector` setup — copy the surrounding test's scaffolding verbatim; only the guide and the two new assertions are new.)

Run: `mise exec -- mix test test/image_pipe/transform/crop_operation_test.exs -k weights`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test
git commit -m "test: objw weight lever (unit), coarse wire proof, crop/no-geometry forms, detect-span weights"
```

---

## Task 6: Cache identity & reuse

**Files:**
- Test: `test/image_pipe/plan/operation_key_data_test.exs`
- Test: `test/image_pipe/cache/key_test.exs`

- [ ] **Step 1: Weights are key material + key_data is a no-op on canonical input**

In `test/image_pipe/plan/operation_key_data_test.exs`, inside the detect `describe`:

```elixir
    test "detect weights are key material" do
      a = KeyData.data(%CropGuided{width: {:px, 10}, height: {:px, 10}, guide: {:detect, {:all, %{"face" => 3.0}}}})
      b = KeyData.data(%CropGuided{width: {:px, 10}, height: {:px, 10}, guide: {:detect, {:all, %{"face" => 2.0}}}})
      refute Keyword.fetch!(a, :guide) == Keyword.fetch!(b, :guide)
    end

    # Spec-mandated: key_data does NOT re-canonicalize — it passes an already-
    # canonical weights map through unchanged, so the parser (sole canonicalizer)
    # and the cache layer cannot drift.
    property "guide_data passes an already-canonical weights map through unchanged" do
      check all entries <-
                  list_of({member_of(["face", "car", "dog"]), member_of([2.0, 3.0])}, max_length: 3),
              default <- member_of([:none, 2.0, 3.0]) do
        weights =
          entries
          |> Map.new()
          |> then(fn m -> if default == :none, do: m, else: Map.put(m, :default, default) end)

        data = KeyData.data(%CropGuided{width: {:px, 10}, height: {:px, 10}, guide: {:detect, {:all, weights}}})
        assert Keyword.fetch!(data, :weights) == weights
      end
    end

    test "equal detect weights serialize identically regardless of map insertion order" do
      a = KeyData.data(%CropGuided{width: {:px, 10}, height: {:px, 10}, guide: {:detect, {:all, %{default: 2.0, "face" => 3.0}}}})
      b = KeyData.data(%CropGuided{width: {:px, 10}, height: {:px, 10}, guide: {:detect, {:all, Map.new([{"face", 3.0}, {:default, 2.0}])}}})
      assert Keyword.fetch!(a, :guide) == Keyword.fetch!(b, :guide)
    end
```

(The serialization is finalized by `Cache.Key.canonicalize/1`, which sorts maps by key — so insertion order is irrelevant at the key level. The `guide_data` no-op property pins that key_data itself adds/drops nothing.)

- [ ] **Step 2: Run (should pass given Task 1)**

Run: `mise exec -- mix test test/image_pipe/plan/operation_key_data_test.exs -k weights`
Expected: PASS.

- [ ] **Step 3: Canonically-equal objw requests share a cache key (hash equality)**

In `test/image_pipe/cache/key_test.exs`, mirror the file's existing `build_key!` + `detect_plan`/`detect_crop_operation` helpers. Build two plans whose objw URLs canonicalize identically (`all:1:face:3` ≡ `face:3`) and assert equal hash. Construct the operations via the same `Operation.crop_guided(...)` helper the file already uses, passing the **canonical guide** directly (the plan builder canonicalization is already covered in Task 4, so here we assert the cache layer keys equal guides equally):

```elixir
  test "canonically-equal detect weights produce the same cache key" do
    conn = conn(:get, "/_/g:objw:all:1:face:3/w:200/h:100/plain/images/cat.jpg")

    {:ok, op} =
      Operation.crop_guided(tagged_dimension(200), tagged_dimension(100), {:detect, {:all, %{"face" => 3.0}}})

    plan = plan(pipelines: [%Pipeline{operations: [op]}])

    k1 = build_key!(conn, plan, source_identity(), detector_identity: {Detector, :v1})
    k2 = build_key!(conn, plan, source_identity(), detector_identity: {Detector, :v1})

    assert k1.hash == k2.hash
  end

  test "different detect weights produce different cache keys" do
    conn = conn(:get, "/_/g:objw:all:1:face:3/w:200/h:100/plain/images/cat.jpg")

    plan_for = fn weights ->
      {:ok, op} = Operation.crop_guided(tagged_dimension(200), tagged_dimension(100), {:detect, {:all, weights}})
      plan(pipelines: [%Pipeline{operations: [op]}])
    end

    k1 = build_key!(conn, plan_for.(%{"face" => 3.0}), source_identity(), detector_identity: {Detector, :v1})
    k2 = build_key!(conn, plan_for.(%{"face" => 2.0}), source_identity(), detector_identity: {Detector, :v1})

    refute k1.hash == k2.hash
  end
```

(Determinism of equal-content/insertion-order is already proven; the meaningful cache-layer claim is equal-guide⇒equal-hash and different-weights⇒different-hash. The end-to-end "second request is a cache hit" is optional: if the wire test file has a `cached_opts`/`CountingOriginImage` reuse helper, add a wire test that a second canonically-equal `objw` URL does not re-fetch origin — mirror that file's exact `assert_received :origin_fetch` / `refute_received :origin_fetch` pattern. Do NOT invent a counter API.)

- [ ] **Step 4: Run cache tests + full suite**

Run: `mise exec -- mix test test/image_pipe/cache/key_test.exs test/image_pipe/plan/operation_key_data_test.exs && mise exec -- mix test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test
git commit -m "test: objw weights are cache-key material; canonical-equal guides share a key"
```

---

## Task 7: Demo, docs, and support matrix

**Files:** `demo/`, `docs/content-aware-gravity.md`, `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Update the support matrix**

In `docs/imgproxy_support_matrix.md`, flip the `objw` row from out/Slice 2 to supported; note `g:`/`c:W:H:` forms and positive-decimal weights with `≤ 0` rejected.

- [ ] **Step 2: Document the feature**

In `docs/content-aware-gravity.md`, add an `objw` section: syntax, `all` baseline / default 1, the filter-vs-weight distinction (`obj:` filters, `objw` weights over everything), the `weight·√area` formula + rationale (responsive lever, dominant object still wins, the honest "uniform favors the biggest box" consequence), and the worked nested-scene table from the spec.

- [ ] **Step 3: Add demo controls**

In `demo/`, add per-class weight controls + URL state alongside the existing object-gravity controls, following the `obj` pattern.

- [ ] **Step 4: Verify the demo build**

Run: `mise run precommit:demo`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs demo
git commit -m "docs: document objw gravity; demo: per-class weight controls"
```

---

## Final verification

- [ ] **Run the full Elixir gate**

Run: `mise run precommit`
Expected: format clean, no warnings, credo strict clean, all tests pass.

---

## Self-review checklist (author)

- **Spec coverage:** guide shape (T1), `√area` formula (T2), grammar incl. decimals/`≤0`/malformed/bare (T3), canonicalization single-home + order-independence + **idempotence** property (T4), telemetry + weight unit proof + crop/no-geometry/`c:` wire forms (T5), cache key material + **key_data no-op property** + canonical-equal key equality (T6), demo + docs + matrix (T7). ✓
- **Type consistency:** `{:detect, {spec, weights}}` everywhere (T1); raw `{:objw, [{class, float}]}` (T3) → `canonical_weights/1` → `{:detect, {:all, map}}` (T4); `Focal.weighted_centroid/4` name + arity stable across T1/T2/T5. ✓
- **Green-at-every-commit:** T1 updates `crop_operation_test.exs` (10 sites) + ALL `plan_builder_test.exs` `{:detect,…}` assertions; behavior-preserving area term keeps pixels identical. T2's √area shift only affects multi-box (none in Slice 1 fixtures). T3's `{:objw,…}` reaches no planner path before T4. ✓
- **Test robustness:** formula/weight pinned by exact `FocalTest` unit tests; wire tests coarse (`refute body ==`) with fixture-scaled boxes + an explicit "widen boxes if clamped" instruction. Telemetry asserts the real `:stop` event shape. No invented cache-counter API. ✓
- **Weights are floats** (`parse_positive_float/1`); `:default` sentinel `1.0`. ✓
