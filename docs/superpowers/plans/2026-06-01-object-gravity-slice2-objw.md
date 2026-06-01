# Object Gravity Slice 2 (`objw` per-class weights) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add imgproxy `gravity:objw:%class:%weight:…` per-class object weighting, so a class weight measurably biases the content-aware crop's focal point.

**Architecture:** The detect guide is reshaped from `{:detect, spec}` to `{:detect, {spec, weights}}` (weights a sparse `%{optional(:default) => float, optional(String.t()) => float}` map; empty = uniform). The imgproxy parser emits a raw `{:objw, pairs}` gravity; the imgproxy plan builder is the sole canonicalizer (translates `all`→`:default`, applies drop rules, always `spec: :all`). The weighted centroid uses `pull = classWeight(label) · √area`, isolated in one private function in the executable crop.

**Tech Stack:** Elixir, ExUnit + StreamData, Plug, the `image`/libvips stack, `:telemetry`.

**Spec:** `docs/superpowers/specs/2026-06-01-object-gravity-slice2-design.md`

**Sequencing rationale:** Task 1 reshapes the guide *behavior-preservingly* (empty weights, `pull = weight · area` so uniform = today's area centroid) so the suite stays green. Task 2 flips the formula to `√area` and pins the (intended) regression. Tasks 3–4 add `objw` parsing + canonicalization. Task 5 wires telemetry + the request-boundary pixel proof. Task 6 covers cache identity/reuse. Task 7 does demo + docs.

**Conventions:**
- Run everything through mise: `mise exec -- mix test …`, `mise exec -- mix format`, etc.
- Weights are **floats** (the parser uses `parse_positive_float/1`), so `objw:all:2:face:3` yields `%{default: 2.0, "face" => 3.0}`. Tests assert floats.
- Gate before finishing broad changes: `mise run precommit`.

---

## File Structure

**Modified (production):**
- `lib/image_pipe/plan/operation/crop_guided.ex` — guide typespec (+ `weights` type).
- `lib/image_pipe/plan/operation/resize.ex` — guide typespec.
- `lib/image_pipe/plan/operation.ex` — `smart_guide/1` validator.
- `lib/image_pipe/plan.ex` — `detect_classes/1`.
- `lib/image_pipe/plan/key_data.ex` — `guide_data/1`.
- `lib/image_pipe/transform/plan_executor.ex` — `tagged_executable_gravity/1`.
- `lib/image_pipe/transform/operation/crop.ex` — guide typespec, `execute/2`, `detect_crop`, `detect_crop_with_module`, `run_detect`, `face_assist_crop`, `focal_from_regions`, new `region_pull`/`class_weight`.
- `lib/image_pipe/parser/imgproxy/option_grammar.ex` — `objw` grammar in `parse_gravity`, `parse_crop_gravity`, `parse_crop`, new `parse_object_weights`.
- `lib/image_pipe/parser/imgproxy/plan_builder.ex` — `object_detect_guide/2`, `canonical_weights/1`, `resize_guide`/`tagged_gravity` clauses for `{:objw, …}`.
- `lib/image_pipe/parser/imgproxy/crop_request.ex` — `gravity()` typespec (add `:obj`/`:objw`).

**Modified (docs/demo):**
- `docs/content-aware-gravity.md`, `docs/imgproxy_support_matrix.md`, `demo/` Svelte controls + URL state.

**Modified (tests):** parser, plan_builder, plan, key_data, cache key, and wire-conformance test files (details in tasks).

---

## Task 1: Reshape the detect guide to `{:detect, {spec, weights}}` (behavior-preserving)

Carry an **empty** weights map everywhere and weight by `pull = classWeight(label) · area` (empty map → weight `1.0` → `area`, identical to today). This is the cross-cutting shape change; it must touch every producer/validator/consumer in one commit so the suite stays green.

**Files:**
- Modify: `lib/image_pipe/plan/operation/crop_guided.ex`, `resize.ex`, `plan/operation.ex`, `plan.ex`, `plan/key_data.ex`, `transform/plan_executor.ex`, `transform/operation/crop.ex`, `parser/imgproxy/plan_builder.ex`
- Test (modify): `test/parser/imgproxy/plan_builder_test.exs`, `test/image_pipe/plan_test.exs`, `test/image_pipe/plan/operation_key_data_test.exs`, `test/image_pipe/cache/key_test.exs`

- [ ] **Step 1: Update a producer test to the new shape (drive the change)**

In `test/parser/imgproxy/plan_builder_test.exs`, change the three `{:detect, …}` expectations to the nested shape:

```elixir
  test "maps face object gravity fill resize to the detect plan guide" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:obj, ["face"]}
             )

    assert [%Operation.Resize{mode: :cover} = resize] = operations
    assert resize.guide == {:detect, {["face"], %{}}}
  end

  test "maps face object gravity crop to the detect plan guide" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]}} =
             plan_pipeline(
               crop: %ImagePipe.Parser.Imgproxy.CropRequest{
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: {:obj, ["face"]}
               }
             )

    assert crop.guide == {:detect, {["face"], %{}}}
  end

  test "bare object gravity maps to detect :all (fill path)" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:obj, []}
             )

    assert resize.guide == {:detect, {:all, %{}}}
  end
```

Also update the dialect-leak test's expected guides:

```elixir
    for {gravity, expected_guide} <- [{:sm, :smart}, {{:obj, ["face"]}, {:detect, {["face"], %{}}}}] do
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/parser/imgproxy/plan_builder_test.exs`
Expected: FAIL — planner still emits `{:detect, ["face"]}` and/or `smart_guide` rejects the new shape.

- [ ] **Step 3: Add the `weights` typespec and update the guide types**

In `lib/image_pipe/plan/operation/crop_guided.ex`, add a `weights` type and replace the two `{:detect, …}` lines:

```elixir
  @type weights :: %{optional(:default) => number(), optional(String.t()) => number()}
  @type guide ::
          anchor()
          | {:anchor, :left | :center | :right, :top | :center | :bottom}
          | {:focal, {:ratio, non_neg_integer(), pos_integer()},
             {:ratio, non_neg_integer(), pos_integer()}}
          | :smart
          | {:smart, :face_assist}
          | {:detect, {:all, weights()}}
          | {:detect, {nonempty_list(String.t()), weights()}}
```

In `lib/image_pipe/plan/operation/resize.ex`, mirror it:

```elixir
  @type weights :: %{optional(:default) => number(), optional(String.t()) => number()}
  @type guide ::
          :center
          | {:anchor, anchor(), anchor()}
          | {:focal, ratio(), ratio()}
          | :smart
          | {:smart, :face_assist}
          | {:detect, {:all, weights()}}
          | {:detect, {nonempty_list(String.t()), weights()}}
```

In `lib/image_pipe/transform/operation/crop.ex`, update the `gravity` field type's two detect lines:

```elixir
            | {:detect, {:all, %{optional(:default) => number(), optional(String.t()) => number()}}}
            | {:detect,
               {[String.t()], %{optional(:default) => number(), optional(String.t()) => number()}}}
```

- [ ] **Step 4: Teach the `smart_guide/1` validator the new shape**

In `lib/image_pipe/plan/operation.ex`, replace the two `{:detect, …}` clauses:

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

- [ ] **Step 5: Emit the new shape from the plan builder**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, replace `object_detect_guide/1`:

```elixir
  # Maps imgproxy object gravity classes to a product-neutral detect guide.
  # Bare `obj` (empty classes) or `all` anywhere collapses to the :all sentinel;
  # otherwise the explicit class list is carried through. Weights are empty here
  # (`obj` has no weights); `objw` supplies them via object_detect_guide/2 in a
  # later clause. Shared by the fill (resize_guide) and crop (tagged_gravity)
  # paths so they cannot diverge.
  defp object_detect_guide(classes), do: object_detect_guide(classes, %{})

  defp object_detect_guide(classes, weights) when is_map(weights) do
    spec = if classes == [] or "all" in classes, do: :all, else: classes
    {:detect, {spec, weights}}
  end
```

(`resize_guide({:obj, classes}, …)` and `tagged_gravity({:obj, classes}, …)` already call `object_detect_guide(classes)` — unchanged.)

- [ ] **Step 6: Update `detect_classes/1` to read `spec` from the tuple**

In `lib/image_pipe/plan.ex`, replace the two `case` clauses inside the reduce:

```elixir
      case Map.get(op, :guide) do
        {:detect, {:all, _weights}} -> {:halt, :all}
        {:detect, {classes, _weights}} when is_list(classes) -> {:cont, classes ++ acc}
        _ -> {:cont, acc}
      end
```

- [ ] **Step 7: Forward the tuple through the executor**

In `lib/image_pipe/transform/plan_executor.ex`, replace the detect clause:

```elixir
  defp tagged_executable_gravity({:detect, {spec, weights}}), do: {:detect, {spec, weights}}
```

- [ ] **Step 8: Serialize weights in the cache key data**

In `lib/image_pipe/plan/key_data.ex`, replace the two `{:detect, …}` clauses. Weights ride as a **map value** (so `Cache.Key.canonicalize/1` deterministically reorders them):

```elixir
  defp guide_data({:detect, {:all, weights}}) when is_map(weights),
    do: [type: :detect, classes: :all, weights: weights]

  defp guide_data({:detect, {classes, weights}}) when is_list(classes) and is_map(weights),
    do: [type: :detect, classes: Enum.sort(classes), weights: weights]
```

- [ ] **Step 9: Thread weights into the crop execution and centroid**

In `lib/image_pipe/transform/operation/crop.ex`:

Update the detect `execute/2` clause to destructure the tuple:

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
           focal_from_regions(regions, image_width(state), image_height(state), weights) do
      execute(%{params | gravity: focal}, state)
    else
      _ -> smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    end
  end
```

Replace `run_detect/5` with `/6` (weights added to span metadata; the detector itself still only receives `:classes`):

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

Update the face-assist call site to pass uniform weights (`%{}`) and the `/6` `run_detect`:

```elixir
  defp face_assist_crop(%__MODULE__{} = params, %State{} = state, module, dopts) do
    with {:ok, [_ | _] = regions} <-
           run_detect(module, dopts, state.image, ["face"], %{}, state.telemetry_opts),
         {:ok, {:fp, fx, fy}} <-
           focal_from_regions(regions, image_width(state), image_height(state), %{}),
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

Replace `focal_from_regions/3` with `/4` plus the `region_pull/2` and `class_weight/2` helpers. **In this task the area function is still `area` (`w*h`)** so behavior is preserved; Task 2 swaps it for `√area`:

```elixir
  defp focal_from_regions(regions, image_width, image_height, weights) do
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

  # Per-region pull on the weighted centroid. Task 2 changes the area term to
  # √area; the class weight is the only Slice 2 addition here.
  defp region_pull(%{box: {_x, _y, w, h}} = region, weights) do
    class_weight(Map.get(region, :label), weights) * (w * h)
  end

  # Resolves a region's class weight: explicit class entry, else the :default
  # baseline, else 1.0. Total over any label (including nil).
  defp class_weight(label, weights) do
    Map.get(weights, label, Map.get(weights, :default, 1.0))
  end
```

- [ ] **Step 10: Update the remaining shape-dependent tests**

`test/image_pipe/plan_test.exs` — the `plan_with_guide/1` helper passes a guide straight to an operation; update the detect cases to the nested shape:

```elixir
  test "detect_classes finds a {:detect, classes} guide" do
    assert Plan.detect_classes(plan_with_guide({:detect, {["face"], %{}}})) == ["face"]
  end

  test "detect_classes returns a guide's classes sorted and deduped" do
    assert Plan.detect_classes(plan_with_guide({:detect, {["dog", "car", "dog"], %{}}})) == [
             "car",
             "dog"
           ]
  end

  test "detect_classes returns :all for an all-objects guide" do
    assert Plan.detect_classes(plan_with_guide({:detect, {:all, %{}}})) == :all
  end
```

`test/image_pipe/plan/operation_key_data_test.exs` — update every `guide: {:detect, …}` literal to `{:detect, {…, %{}}}`, and the `:all` case's expected value:

```elixir
    test "detect :all guide encodes as classes: :all" do
      data =
        KeyData.data(%CropGuided{width: {:px, 100}, height: {:px, 100}, guide: {:detect, {:all, %{}}}})

      assert Keyword.fetch!(data, :guide) == [type: :detect, classes: :all, weights: %{}]
    end
```

For the property and "sorted/distinct" tests in that file, wrap each `guide: {:detect, classes}` as `guide: {:detect, {classes, %{}}}` (and shuffled likewise). For the "three content-aware guides serialize distinctly" test use `{:detect, {["face"], %{}}}`.

`test/image_pipe/cache/key_test.exs` — update the `detect_crop_operation/2` helper:

```elixir
  defp detect_crop_operation(width, height) do
    assert {:ok, operation} =
             Operation.crop_guided(
               tagged_dimension(width),
               tagged_dimension(height),
               {:detect, {["face"], %{}}}
             )

    operation
  end
```

- [ ] **Step 11: Run the full suite**

Run: `mise exec -- mix test`
Expected: PASS. (Pixel results are unchanged: empty weights ⇒ `1.0 · area` ⇒ today's area centroid.)

- [ ] **Step 12: Format, compile clean, commit**

Run: `mise exec -- mix format && mise exec -- mix compile --warnings-as-errors`
Expected: no warnings.

```bash
git add lib test
git commit -m "refactor: reshape detect guide to {:detect, {spec, weights}} (behavior-preserving)"
```

---

## Task 2: Switch the weighted centroid to `weight·√area`

Flip the area term from `w*h` to `√(w*h)`. Single-box detections are unaffected (the centroid is the box center under any area function), so Slice 1's single-box wire tests stay green; only multi-region equal-weight crops shift. Pin the new behavior with a focused test.

**Files:**
- Modify: `lib/image_pipe/transform/operation/crop.ex` (`region_pull/2`)
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs` (new multi-box detector + centroid test)

- [ ] **Step 1: Write the failing multi-region regression test**

In `test/image_pipe/imgproxy_wire_conformance_test.exs`, add a two-box detector near the other test detectors (after `CornerObjectDetector`):

```elixir
  # Slice 2: TwoBoxDetector — a large box low-right and a small box high-left, so
  # the equal-weight centroid sits between them and a face weight can pull it.
  defmodule TwoBoxDetector do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_), do: ["face", "person"]

    @impl true
    def available?(opts), do: Keyword.get(opts, :available?, true)

    @impl true
    def identity(_), do: {__MODULE__, :v1}

    @impl true
    def detect(_image, _opts) do
      {:ok,
       [
         %{label: "person", score: 0.95, box: {120, 120, 80, 80}},
         %{label: "face", score: 0.95, box: {10, 10, 20, 20}}
       ]}
    end
  end
```

Then a test asserting the `√area` centroid differs from the old pure-`area` centroid. Under pure `area` the big `person` box (area 6400) dominates the small `face` (area 400) 16:1; under `√area` it is 80:20 = 4:1, so the crop sits noticeably closer to the small box. We assert the `obj:all` crop is distinct from a `g:ce` (center) crop and from an attention crop — and, to pin the formula, that it is **not** equal to a synthetic "person-only" crop (which is what a pure-area centroid would approximate):

```elixir
  # Slice 2: the √area centroid gives the small box meaningfully more pull than a
  # pure-area centroid would, so an all-objects crop over a big+small scene is
  # distinct from a crop centered on the big box alone.
  test "all-objects crop uses √area weighting (small box is not drowned out)" do
    opts = Keyword.merge(@default_opts, detector: TwoBoxDetector)

    all = call_imgproxy("/_/rs:fill:50:50/g:obj:all/f:jpeg/plain/images/beach.jpg", opts)
    big_only = call_imgproxy("/_/rs:fill:50:50/g:obj:person/f:jpeg/plain/images/beach.jpg", opts)

    assert all.status == 200
    assert dimensions(all) == {50, 50}
    # person-only detection returns just the big box → centroid at its center.
    # The √area all-objects centroid is pulled toward the small box, so differs.
    refute all.resp_body == big_only.resp_body
  end
```

Note: `g:obj:person` makes `TwoBoxDetector` still return both boxes (it ignores classes), but `focal_from_regions` only sees what the detector returns. To make `big_only` truly the big box alone, give the detector class-awareness:

```elixir
    @impl true
    def detect(_image, opts) do
      boxes = [
        %{label: "person", score: 0.95, box: {120, 120, 80, 80}},
        %{label: "face", score: 0.95, box: {10, 10, 20, 20}}
      ]

      case Keyword.get(opts, :classes, :all) do
        :all -> {:ok, boxes}
        classes -> {:ok, Enum.filter(boxes, &(&1.label in List.wrap(classes)))}
      end
    end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs -k "√area"`
Expected: FAIL — with pure `area`, the all-objects centroid is dominated by the big box and renders ~identically to person-only.

- [ ] **Step 3: Switch the area term to √area**

In `lib/image_pipe/transform/operation/crop.ex`, change `region_pull/2`:

```elixir
  # Per-region pull on the weighted centroid: class weight × √area. √area tracks
  # the box's linear size, so a class weight is a responsive lever (a face boost
  # actually moves the crop) while a genuinely dominant object still wins. See the
  # Slice 2 design doc for the formula rationale.
  defp region_pull(%{box: {_x, _y, w, h}} = region, weights) do
    class_weight(Map.get(region, :label), weights) * :math.sqrt(w * h)
  end
```

- [ ] **Step 4: Run the new test and the full suite**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS.

Run: `mise exec -- mix test`
Expected: PASS. If any pre-existing multi-region focal-coordinate assertion fails, it is the intended `√area` shift — update that assertion's expected value and note it in the commit. (Single-box tests will not move.)

- [ ] **Step 5: Commit**

```bash
git add lib test
git commit -m "feat: weight object-gravity centroid by √area (responsive class-weight lever)"
```

---

## Task 3: Parse `objw` grammar in the imgproxy option grammar

Add `objw` to the three bespoke entry points (`parse_gravity`, `parse_crop_gravity`, `parse_crop`). Variable-arity, so **not** an `@special_specs` entry. Emit a raw `{:objw, [{class, weight_float}]}` gravity; reject malformed input at this boundary.

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex`
- Modify: `lib/image_pipe/parser/imgproxy/crop_request.ex` (typespec)
- Test: `test/parser/imgproxy/option_grammar_test.exs`

- [ ] **Step 1: Write failing parser tests**

In `test/parser/imgproxy/option_grammar_test.exs`, add:

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
    assert OptionGrammar.parse("g:objw:face:2.5") ==
             {:ok,
              {:pipeline,
               [
                 gravity: {:objw, [{"face", 2.5}]},
                 gravity_x_offset: {:pixels, 0.0},
                 gravity_y_offset: {:pixels, 0.0}
               ]}}
  end

  test "crop objw gravity parses class/weight pairs" do
    assert OptionGrammar.parse("c:100:100:objw:all:1:face:3") ==
             {:ok,
              {:pipeline,
               [
                 crop: %CropRequest{
                   width: {:pixels, 100},
                   height: {:pixels, 100},
                   gravity: {:objw, [{"all", 1.0}, {"face", 3.0}]}
                 }
               ]}}
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
Expected: FAIL — `objw` falls through to `{:error, {:invalid_option_segment, _}}` for all.

- [ ] **Step 3: Add the `objw` gravity clause + pair parser**

In `lib/image_pipe/parser/imgproxy/option_grammar.ex`, add an `objw` clause to `parse_gravity` (place it just after the `obj` clause). The guard `pairs != []` makes bare `objw` fall through to the catch-all reject:

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

Add the pair parser near `parse_crop_gravity` (a single private function, reused by the crop path):

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

Add an `objw` clause to `parse_crop_gravity` (after the `obj` clause), passing `"crop"` as the segment (matching the existing `obj`/fallback convention in that function):

```elixir
  defp parse_crop_gravity(["objw" | pairs]) do
    with {:ok, weights} <- parse_object_weights(pairs, "crop") do
      {:ok, {:objw, weights}}
    end
  end
```

Add the inline `parse_crop` clause (after the `obj` crop clause at ~line 745) so `c:W:H:objw:…` routes through `parse_crop_gravity`:

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

In `lib/image_pipe/parser/imgproxy/crop_request.ex`, the `gravity()` type currently omits even `:obj`. Add both object forms:

```elixir
  @type gravity() ::
          {:anchor, :left | :center | :right, :top | :center | :bottom}
          | {:fp, float(), float()}
          | {:obj, [String.t()]}
          | {:objw, [{String.t(), float()}]}
          | :sm
          | nil
```

- [ ] **Step 6: Run the parser tests + full suite**

Run: `mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs`
Expected: PASS.

Run: `mise exec -- mix test`
Expected: PASS (the planner doesn't yet handle `{:objw, …}`; no production path produces it except these new parser tests, which only assert the parser output).

- [ ] **Step 7: Format and commit**

```bash
git add lib test
git commit -m "feat: parse imgproxy objw class/weight gravity grammar"
```

---

## Task 4: Translate `{:objw, …}` to a canonical detect guide in the plan builder

The plan builder is the **sole canonicalizer**: `all`→`:default`, drop rules, always `spec: :all`.

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex`
- Test: `test/parser/imgproxy/plan_builder_test.exs`

- [ ] **Step 1: Write failing plan-builder tests**

In `test/parser/imgproxy/plan_builder_test.exs`, add:

```elixir
  test "objw maps to a detect :all guide with a canonical weights map" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:objw, [{"all", 1.0}, {"face", 3.0}]}
             )

    assert resize.guide == {:detect, {:all, %{"face" => 3.0}}}
  end

  test "objw all baseline above 1 is carried; class equal to default is dropped" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}]}} =
             plan_pipeline(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: {:objw, [{"all", 3.0}, {"car", 3.0}]}
             )

    assert resize.guide == {:detect, {:all, %{default: 3.0}}}
  end

  test "objw canonicalizes equivalent URLs to the same guide" do
    a = objw_guide([{"face", 3.0}])
    b = objw_guide([{"all", 1.0}, {"face", 3.0}])
    assert a == b
    assert a == {:detect, {:all, %{"face" => 3.0}}}
  end

  test "objw maps through the crop path identically (no fill/crop divergence)" do
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

Add the helper near the other test helpers in that file:

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
Expected: FAIL — `resize_guide`/`tagged_gravity` have no `{:objw, …}` clause.

- [ ] **Step 3: Add `{:objw, …}` clauses and the canonicalizer**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, add `objw` clauses next to the `obj` ones in **both** `resize_guide` and `tagged_gravity`:

```elixir
  defp resize_guide({:objw, pairs}, _face_assist), do: {:ok, object_detect_guide([], canonical_weights(pairs))}
```

```elixir
  defp tagged_gravity({:objw, pairs}, _face_assist), do: {:ok, object_detect_guide([], canonical_weights(pairs))}
```

(Passing `classes: []` makes `object_detect_guide/2` collapse `spec` to `:all`, which is exactly imgproxy's "objw weights over everything" semantics.)

Add `canonical_weights/1` near `object_detect_guide/2`:

```elixir
  # Canonicalizes raw imgproxy objw pairs into the sparse plan weights map.
  # `all` → :default; then the fixed-point drop rules: drop class entries equal
  # to the effective default, and drop :default itself when it is 1.0. Later
  # pairs win on duplicate keys. This is the sole canonicalization site.
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

- [ ] **Step 4: Run the tests + full suite**

Run: `mise exec -- mix test test/parser/imgproxy/plan_builder_test.exs`
Expected: PASS.

Run: `mise exec -- mix test`
Expected: PASS.

- [ ] **Step 5: Add a canonicalization property test**

In `test/parser/imgproxy/plan_builder_test.exs`, assert idempotence/convergence over shuffled equivalent inputs:

```elixir
  property "objw canonicalization is order-independent and idempotent" do
    check all classes <- uniq_list_of(member_of(["face", "car", "dog", "person"]), min_length: 1, max_length: 4),
              weights <- list_of(member_of([1.0, 2.0, 3.0]), length: length(classes)),
              default <- member_of([1.0, 2.0, 3.0]) do
      pairs = [{"all", default} | Enum.zip(classes, weights)]
      guide_a = objw_guide(pairs)
      guide_b = objw_guide(Enum.shuffle(pairs))
      assert guide_a == guide_b
    end
  end
```

Ensure `use ExUnitProperties` (and `import StreamData`-style generators) is present in the file — copy the pattern from `operation_key_data_test.exs` if not already imported.

- [ ] **Step 6: Run and commit**

Run: `mise exec -- mix test test/parser/imgproxy/plan_builder_test.exs`
Expected: PASS.

```bash
git add lib test
git commit -m "feat: canonicalize objw weights into the detect plan guide"
```

---

## Task 5: Request-boundary pixel proof + telemetry weights

Prove at the wire that a face boost is a responsive dial, and that the resolved weights ride the detect span. Cover the no-geometry and `c:` crop forms.

**Files:**
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs`
- Test: `test/image_pipe/telemetry/logger_test.exs` (or the existing detect-span telemetry test file)

- [ ] **Step 1: Write the failing pixel + form tests**

In `test/image_pipe/imgproxy_wire_conformance_test.exs`, reuse `TwoBoxDetector` (Task 2). Add:

```elixir
  # Slice 2: objw is a responsive dial — increasing a class weight monotonically
  # walks the crop from the uniform centroid toward the boosted class's box. We
  # render uniform, two boost levels, and the face-only filter (the limit) and
  # assert all four are pixel-distinct.
  test "objw face weight measurably moves the crop (and scales with the weight)" do
    opts = Keyword.merge(@default_opts, detector: TwoBoxDetector)

    uniform = call_imgproxy("/_/rs:fill:50:50/g:obj:all/f:jpeg/plain/images/beach.jpg", opts)
    boost2 = call_imgproxy("/_/rs:fill:50:50/g:objw:all:1:face:2/f:jpeg/plain/images/beach.jpg", opts)
    boost8 = call_imgproxy("/_/rs:fill:50:50/g:objw:all:1:face:8/f:jpeg/plain/images/beach.jpg", opts)
    face_only = call_imgproxy("/_/rs:fill:50:50/g:obj:face/f:jpeg/plain/images/beach.jpg", opts)

    for r <- [uniform, boost2, boost8, face_only] do
      assert r.status == 200
      assert dimensions(r) == {50, 50}
    end

    bodies = Enum.map([uniform, boost2, boost8, face_only], & &1.resp_body)
    assert bodies == Enum.uniq(bodies)
  end

  # Slice 2: objw canonicalizes to obj:all when all weights are equal → identical
  # crop (and, separately, identical cache key — see the cache task).
  test "objw with uniform weights renders identically to obj:all" do
    opts = Keyword.merge(@default_opts, detector: TwoBoxDetector)

    objw = call_imgproxy("/_/rs:fill:50:50/g:objw:all:2/f:jpeg/plain/images/beach.jpg", opts)
    obj = call_imgproxy("/_/rs:fill:50:50/g:obj:all/f:jpeg/plain/images/beach.jpg", opts)

    assert objw.resp_body == obj.resp_body
  end

  # Slice 2: the c:W:H:objw form reaches the crop path and biases the crop.
  test "c:W:H:objw crop form applies the weight" do
    opts = Keyword.merge(@default_opts, detector: TwoBoxDetector)

    weighted = call_imgproxy("/_/c:50:50:objw:all:1:face:8/f:jpeg/plain/images/beach.jpg", opts)
    uniform = call_imgproxy("/_/c:50:50:obj:all/f:jpeg/plain/images/beach.jpg", opts)

    assert weighted.status == 200
    refute weighted.resp_body == uniform.resp_body
  end

  # Slice 2: no-geometry objw returns 200.
  test "no-geometry g:objw returns 200 without a resize or crop" do
    opts = Keyword.merge(@default_opts, detector: TwoBoxDetector)
    conn = call_imgproxy("/_/g:objw:all:1:face:3/plain/images/beach.jpg", opts)
    assert conn.status == 200
  end
```

- [ ] **Step 2: Run to verify (they should already pass given Tasks 1–4)**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs -k objw`
Expected: PASS. (If "uniform renders identically" fails, the canonicalization in Task 4 isn't collapsing `all:2` to uniform — fix there.) These are the spec's mandated request-boundary pixel proofs; keep them even though the machinery already exists.

- [ ] **Step 3: Write the failing telemetry test**

Find the existing detect-span telemetry assertion (search `test/` for `[:transform, :detect]` / `:classes` in a telemetry/logger test). Add a sibling asserting `weights` is present in the span's start metadata. Pattern (adapt to the file's existing `attach`/handler style):

```elixir
  test "the detect span carries the resolved weights map" do
    opts = Keyword.merge(@default_opts, detector: TwoBoxDetector)

    ref = attach_detect_span_handler()
    _ = call_imgproxy("/_/rs:fill:50:50/g:objw:all:1:face:3/f:jpeg/plain/images/beach.jpg", opts)

    assert_received {^ref, :start, %{classes: :all, weights: %{"face" => 3.0}}}
  end
```

If the project has no detect-span metadata test yet, mirror the `[:transform, :detect, :blend]` one-shot test that already exists and assert on `[:transform, :detect]` start metadata via `:telemetry.attach/4`.

- [ ] **Step 4: Run telemetry test**

Run: `mise exec -- mix test <telemetry test file>`
Expected: PASS (weights were added to the span in Task 1, Step 9).

- [ ] **Step 5: Commit**

```bash
git add test
git commit -m "test: wire-level objw pixel proof, crop/no-geometry forms, detect-span weights"
```

---

## Task 6: Cache identity & reuse

Weights are key material; semantically-equal `objw` URLs must share a key (cache hit).

**Files:**
- Test: `test/image_pipe/plan/operation_key_data_test.exs` (weight key data)
- Test: `test/image_pipe/cache/key_test.exs` or the wire test (cache reuse)

- [ ] **Step 1: Write failing key-data weight tests**

In `test/image_pipe/plan/operation_key_data_test.exs`, inside the detect `describe`:

```elixir
    test "detect weights are key material" do
      a = KeyData.data(%CropGuided{width: {:px, 10}, height: {:px, 10}, guide: {:detect, {:all, %{"face" => 3.0}}}})
      b = KeyData.data(%CropGuided{width: {:px, 10}, height: {:px, 10}, guide: {:detect, {:all, %{"face" => 2.0}}}})
      refute Keyword.fetch!(a, :guide) == Keyword.fetch!(b, :guide)
    end

    test "equal detect weights serialize identically regardless of map construction order" do
      a = KeyData.data(%CropGuided{width: {:px, 10}, height: {:px, 10}, guide: {:detect, {:all, %{default: 2.0, "face" => 3.0}}}})
      b = KeyData.data(%CropGuided{width: {:px, 10}, height: {:px, 10}, guide: {:detect, {:all, Map.new([{"face", 3.0}, {:default, 2.0}])}}})
      assert Keyword.fetch!(a, :guide) == Keyword.fetch!(b, :guide)
    end
```

- [ ] **Step 2: Run (should pass given Task 1, Step 8)**

Run: `mise exec -- mix test test/image_pipe/plan/operation_key_data_test.exs -k weights`
Expected: PASS (maps are emitted as-is; `canonicalize/1` orders them at serialization).

- [ ] **Step 3: Write the failing wire cache-reuse test**

In the wire-conformance test, assert that two canonically-equal `objw` URLs reuse the cached response. Use the project's existing cache-config + source-counting pattern (search the wire test for `cache:` opts and any "source fetched once" helper; reuse it). Sketch:

```elixir
  # Slice 2: objw:all:1:face:3 and objw:face:3 canonicalize identically, so the
  # second request must hit cache (no second source fetch).
  test "canonically-equal objw requests share a cache entry" do
    {opts, source_counter} = caching_opts_with_source_counter(detector: TwoBoxDetector)

    first = call_imgproxy("/_/rs:fill:50:50/g:objw:all:1:face:3/f:jpeg/plain/images/beach.jpg", opts)
    second = call_imgproxy("/_/rs:fill:50:50/g:objw:face:3/f:jpeg/plain/images/beach.jpg", opts)

    assert first.status == 200
    assert second.status == 200
    assert second.resp_body == first.resp_body
    assert source_fetch_count(source_counter) == 1
  end
```

If no such caching+counter helper exists in the wire test, instead assert key equality directly in `test/image_pipe/cache/key_test.exs` using its `build_key!` helper:

```elixir
  test "canonically-equal objw plans produce the same cache key" do
    conn = conn(:get, "/_/g:objw:all:1:face:3/w:200/h:100/plain/images/cat.jpg")

    {:ok, plan_a} = build_plan("/_/g:objw:all:1:face:3/w:200/h:100/plain/images/cat.jpg")
    {:ok, plan_b} = build_plan("/_/g:objw:face:3/w:200/h:100/plain/images/cat.jpg")

    ka = build_key!(conn, plan_a, source_identity(), detector_identity: {Detector, :v1})
    kb = build_key!(conn, plan_b, source_identity(), detector_identity: {Detector, :v1})

    assert ka.hash == kb.hash
  end
```

(Use whatever plan-building helper that test file already has; if it only builds plans inline, mirror that. The key claim: equal canonical guide ⇒ equal hash.)

- [ ] **Step 4: Run the cache tests + full suite**

Run: `mise exec -- mix test test/image_pipe/cache/key_test.exs test/image_pipe/plan/operation_key_data_test.exs`
Expected: PASS.

Run: `mise exec -- mix test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test
git commit -m "test: objw weights are cache-key material; canonical-equal requests reuse cache"
```

---

## Task 7: Demo, docs, and support matrix

**Files:**
- Modify: `demo/` Svelte controls + URL state (per the demo guideline)
- Modify: `docs/content-aware-gravity.md`
- Modify: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Update the support matrix**

In `docs/imgproxy_support_matrix.md`, find the `objw` row (marked out / Slice 2) and flip it to supported, noting `g:` and `c:W:H:` forms and the positive-decimal weights with `≤ 0` rejected.

- [ ] **Step 2: Document the feature**

In `docs/content-aware-gravity.md`, add an `objw` section: syntax, the `all` baseline / default 1, the filter-vs-weight distinction (`obj:` filters, `objw` weights over everything), the `weight·√area` formula and its rationale (responsive lever, dominant object still wins, honest "uniform favors the biggest box" consequence), and the worked nested-scene table from the spec.

- [ ] **Step 3: Add demo controls**

In the `demo/` Svelte app, add per-class weight controls and URL state alongside the existing object-gravity controls so `objw` is exercisable end-to-end. Follow the existing control/URL-state pattern for `obj`.

- [ ] **Step 4: Verify the demo build**

Run: `mise run precommit:demo`
Expected: PASS (Elixir gate + `mix demo.verify`).

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

- [ ] **Confirm the headline behavior by hand (optional)**

Render `g:obj:all` vs `g:objw:all:1:face:8` against an image with a detector that returns a small face inside a larger box and confirm the crop shifts toward the face.

---

## Self-review checklist (author)

- **Spec coverage:** guide shape (T1), `√area` formula + regression (T2), parser grammar incl. decimals/`≤0`/malformed (T3), canonicalization single-home + property (T4), pixel proof + telemetry + crop/no-geometry forms (T5), cache key material + reuse (T6), demo + docs + matrix (T7). ✓
- **Type consistency:** `{:detect, {spec, weights}}` used identically across T1 sites; `{:objw, [{class, float}]}` raw parser shape (T3) → `canonical_weights/1` → `{:detect, {:all, map}}` (T4); `region_pull/2` + `class_weight/2` names stable (T1/T2). ✓
- **Weights are floats** throughout (parser uses `parse_positive_float/1`); default sentinel is `1.0`. ✓
