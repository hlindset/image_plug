# Smart Gravity & ML Detection Seam — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add content-aware crop anchoring to ImagePipe — imgproxy `g:sm` (libvips attention), `g:obj:face` (optional face detection), and `smart_crop_face_detection` (attention⊕face blend) — built on one product-neutral, host-implementable `Detector` seam.

**Architecture:** Extend the shared plan `guide` union with `:smart` / `{:smart, :face_assist}` / `{:detect, classes}`; route all three through the existing `tagged_executable_gravity/1` so both cover-resize and `c:` crop honor them. The `Crop` transform gains attention/detection branches; the optional `image_vision` dependency is reached through a `Detector` behaviour resolved as config data. Spec: `docs/superpowers/specs/2026-05-30-smart-gravity-design.md` (v3).

**Tech Stack:** Elixir, `image`/`vix` (libvips, `Vix.Vips.Operation.smartcrop/3`), optional `image_vision` (`Image.FaceDetection`), `Boundary`, `:telemetry`, ExUnit + StreamData.

**Run commands:** always via mise — `mise exec -- mix test <path>`, `mise exec -- mix format`, `mise exec -- mix compile --warnings-as-errors`, `mise exec -- mix credo --strict`. Gate before finishing a phase: `mise run precommit`.

---

## Phasing

Each phase ends green and is independently shippable:

- **Phase 1 — `g:sm` → libvips attention.** No dependency, no detector. Plan repr, cache key, executor smartcrop branch, parser mapping (gravity + crop), tests, demo, matrix. Ships smart crop on its own.
- **Phase 2 — `Detector` seam + `g:obj:face`.** Behaviour + `ImageVision` adapter (optional dep), `State`/config threading, fallback ladder, strict pre-fetch gate, `Plan.detect_classes/1`, cache identity, telemetry span, arch tests.
- **Phase 3 — face-assist blend.** `smart_crop_face_detection` config → `{:smart, :face_assist}`, attention⊕face blend execution, cache distinctness.
- **Phase 4 — eager warmup worker.** `warmup/1` callback, `Detector.warmup/2`, `Detector.Warmup` GenServer.

A worker may stop after any phase with working software.

---

## File Structure

**Phase 1**
- Modify: `lib/image_pipe/plan/operation/crop_guided.ex` — add guide variants to `@type`.
- Modify: `lib/image_pipe/plan/operation/resize.ex` — add guide variants to `@type`.
- Verify/Modify: `lib/image_pipe/plan/operation.ex` — guide acceptance in `crop_guided`/`resize` constructors (if they validate).
- Modify: `lib/image_pipe/plan/key_data.ex` — `guide_data/1` clauses.
- Modify: `lib/image_pipe/transform/operation/crop.ex` — `:smart` attention branch via `Vix.Vips.Operation.smartcrop/3`.
- Modify: `lib/image_pipe/transform/plan_executor.ex` — `tagged_executable_gravity/1` for `:smart`.
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex` — `parse_gravity`/`parse_crop_gravity`/`parse_crop` `obj` tails (Phase 1 keeps only `:sm` mapping changes; obj parsing lands here too but maps to reject until Phase 2).
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex` — `:sm` → `:smart` in `tagged_gravity`/`resize_guide`; remove the two `:sm` rejections.
- Test: `test/image_pipe/transform/operation/crop_test.exs`, `test/image_pipe/plan/key_data_test.exs`, `test/image_pipe/parser/imgproxy/*`, a wire-level plug test.

**Phase 2**
- Create: `lib/image_pipe/transform/detector.ex` (behaviour), `lib/image_pipe/transform/detector/image_vision.ex` (adapter).
- Modify: `lib/image_pipe/transform.ex` — export `Detector`; `lib/image_pipe/transform/state.ex` — `detector`/`detector_required` fields.
- Modify: `lib/image_pipe/transform/plan_executor.ex` — populate State from opts; `crop.ex` — `{:detect, _}` branch + fallback ladder + return validation.
- Create: `lib/image_pipe/plan.ex` accessor `detect_classes/1` (or a small `lib/image_pipe/plan/inspect.ex` if Plan is large — follow the file's conventions).
- Modify: `lib/image_pipe/plug.ex` — `detector`/`detector_required` options + strict pre-fetch gate; `lib/image_pipe/cache.ex` + `lib/image_pipe/cache/key.ex` — thread detector identity; `lib/image_pipe/telemetry/*` — `[:transform, :detect]` span + logger registration.
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex` — `{:obj, ["face"]}` → `{:detect, ["face"]}`; reject bare/`all`/multi/`objw`.
- Modify: `mix.exs` — env-gated `image_vision` dep.
- Test: detector adapter test, DI-fake execution tests, strict-gate wire test, cache identity test, telemetry test, arch boundary tests.

**Phase 3**
- Modify: `plan_builder.ex` (read `smart_crop_face_detection`), `crop.ex` (blend), `key_data.ex` (already has the clause), demo.

**Phase 4**
- Create: `lib/image_pipe/transform/detector/warmup.ex`; modify `transform.ex` exports.

---

# PHASE 1 — `g:sm` → libvips attention

### Task 1: Add `:smart` and friends to the plan `guide` types

**Files:**
- Modify: `lib/image_pipe/plan/operation/crop_guided.ex:26-31`
- Modify: `lib/image_pipe/plan/operation/resize.ex` (the `@type guide` / guide field)

- [ ] **Step 1: Extend `CropGuided` guide type**

In `lib/image_pipe/plan/operation/crop_guided.ex`, replace the `@type guide` (lines 26-30) with:

```elixir
  @type guide ::
          anchor()
          | {:anchor, :left | :center | :right, :top | :center | :bottom}
          | {:focal, {:ratio, non_neg_integer(), pos_integer()},
             {:ratio, non_neg_integer(), pos_integer()}}
          | :smart
          | {:smart, :face_assist}
          | {:detect, [String.t()]}
```

- [ ] **Step 2: Extend `Resize` guide type**

Open `lib/image_pipe/plan/operation/resize.ex`, find its `@type guide` (it mirrors `CropGuided`), and add the same three variants (`:smart`, `{:smart, :face_assist}`, `{:detect, [String.t()]}`).

- [ ] **Step 3: Verify constructor acceptance**

Read `lib/image_pipe/plan/operation.ex` and find `crop_guided/4` and `resize/4`. If either validates the `guide` argument against a fixed set (a `case`/guard that would reject `:smart`), add the three new variants to the accepted set. If they pass the guide through unvalidated, no change is needed.

- [ ] **Step 4: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean (type-only change).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plan/operation/crop_guided.ex lib/image_pipe/plan/operation/resize.ex lib/image_pipe/plan/operation.ex
git commit -m "feat(plan): add :smart/:face_assist/:detect guide variants"
```

---

### Task 2: Cache-key serialization for the new guides

**Files:**
- Modify: `lib/image_pipe/plan/key_data.ex:186-192`
- Test: `test/image_pipe/plan/key_data_test.exs`

- [ ] **Step 1: Write failing tests**

Add to `test/image_pipe/plan/key_data_test.exs` (create the file if missing, with `use ExUnit.Case, async: true` and `alias ImagePipe.Plan.KeyData`):

```elixir
describe "guide_data via CropGuided cache data" do
  test "the three content-aware guides serialize distinctly" do
    smart = KeyData.data(%ImagePipe.Plan.Operation.CropGuided{width: {:px, 10}, height: {:px, 10}, guide: :smart})
    assist = KeyData.data(%ImagePipe.Plan.Operation.CropGuided{width: {:px, 10}, height: {:px, 10}, guide: {:smart, :face_assist}})
    detect = KeyData.data(%ImagePipe.Plan.Operation.CropGuided{width: {:px, 10}, height: {:px, 10}, guide: {:detect, ["face"]}})

    guides = Enum.map([smart, assist, detect], &Keyword.fetch!(&1, :guide))
    assert guides == Enum.uniq(guides)
  end

  test "detect classes are sorted and serialized as strings" do
    a = KeyData.data(%ImagePipe.Plan.Operation.CropGuided{width: {:px, 10}, height: {:px, 10}, guide: {:detect, ["b", "a"]}})
    b = KeyData.data(%ImagePipe.Plan.Operation.CropGuided{width: {:px, 10}, height: {:px, 10}, guide: {:detect, ["a", "b"]}})
    assert Keyword.fetch!(a, :guide) == Keyword.fetch!(b, :guide)
  end
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/plan/key_data_test.exs`
Expected: FAIL — `guide_data(:smart)` raises `FunctionClauseError`.

- [ ] **Step 3: Add `guide_data/1` clauses**

In `lib/image_pipe/plan/key_data.ex`, immediately after line 192 (`defp guide_data({:focal, x, y}), do: ...`), add:

```elixir
  defp guide_data(:smart), do: [type: :smart]

  defp guide_data({:smart, :face_assist}), do: [type: :smart, assist: :face]

  defp guide_data({:detect, classes}) when is_list(classes),
    do: [type: :detect, classes: Enum.sort(classes)]
```

Note: `classes` is serialized terminally as a sorted string list — it is **not** routed back through `data/1` (which has no string clause and would raise).

- [ ] **Step 4: Run — expect pass**

Run: `mise exec -- mix test test/image_pipe/plan/key_data_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plan/key_data.ex test/image_pipe/plan/key_data_test.exs
git commit -m "feat(cache): serialize :smart/:face_assist/:detect guides into key data"
```

---

### Task 3: Route `:smart` through the executor

**Files:**
- Modify: `lib/image_pipe/transform/plan_executor.ex:442-454`

- [ ] **Step 1: Add `tagged_executable_gravity/1` clauses**

In `lib/image_pipe/transform/plan_executor.ex`, after the `{:focal, x, y}` clause (line 453-454), add:

```elixir
  defp tagged_executable_gravity(:smart), do: :smart
  defp tagged_executable_gravity({:smart, :face_assist}), do: {:smart, :face_assist}
  defp tagged_executable_gravity({:detect, classes}), do: {:detect, classes}
```

- [ ] **Step 2: Compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean (the `Crop` struct accepts any `gravity` term; the next task makes it execute).

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/transform/plan_executor.ex
git commit -m "feat(transform): map :smart/:detect guides to executable gravity"
```

---

### Task 4: `Crop` attention branch via `smartcrop`

**Files:**
- Modify: `lib/image_pipe/transform/operation/crop.ex`
- Test: `test/image_pipe/transform/operation/crop_test.exs`

- [ ] **Step 1: Write a failing transform test**

Add to `test/image_pipe/transform/operation/crop_test.exs` (follow the file's existing setup for building a `%State{image: ...}` from a fixture; if there's a test helper that loads an image, reuse it):

```elixir
describe "smart gravity" do
  test "smart crop produces the requested dimensions" do
    image = Image.open!("test/support/fixtures/<an-existing-fixture>.png")
    state = %ImagePipe.Transform.State{image: image}

    op = %ImagePipe.Transform.Operation.Crop{
      width: {:pixels, 100},
      height: {:pixels, 100},
      crop_from: :gravity,
      gravity: :smart
    }

    assert {:ok, %{image: out}} = ImagePipe.Transform.Operation.Crop.execute(op, state)
    assert Image.width(out) == 100
    assert Image.height(out) == 100
  end
end
```

(Use a real fixture path from `test/support/fixtures` — list it first with `ls test/support/fixtures`.)

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/transform/operation/crop_test.exs`
Expected: FAIL — `:smart` falls through `crop_gravity/1` to `{:error, {:invalid_crop_gravity, :smart}}`.

- [ ] **Step 3: Add the smart branch to `execute/2`**

In `lib/image_pipe/transform/operation/crop.ex`, change `execute/2` (line 135) to branch on a smart gravity before coordinate cropping. Replace the body of `execute/2` with:

```elixir
  @impl ImagePipe.Transform
  def execute(%__MODULE__{gravity: :smart} = params, %State{} = state) do
    smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
  end

  def execute(%__MODULE__{} = params, %State{} = state) do
    image_width = image_width(state)
    image_height = image_height(state)

    case crop_coordinates(params, state, image_width, image_height) do
      {:ok, %{left: left, top: top, width: crop_width, height: crop_height}} ->
        case Image.crop(state.image, left, top, crop_width, crop_height) do
          {:ok, cropped_image} -> {:ok, set_image(state, cropped_image)}
          {:error, error} -> {:error, {__MODULE__, error}}
        end

      {:error, error} ->
        {:error, {__MODULE__, error}}
    end
  end
```

Then add private helpers (near the bottom, before the final `end`):

```elixir
  # Resolve the target crop size (respecting :auto + aspect ratio) and let
  # libvips choose the window via smartcrop. Used by :smart and the detector
  # fallback. Returns the cropped image; `attention/2` exposes the chosen point
  # for the face-assist blend (Phase 3).
  defp smart_crop(%__MODULE__{} = params, %State{} = state, interesting) do
    image_width = image_width(state)
    image_height = image_height(state)

    with {:ok, crop} <- crop_dimensions(params, image_width, image_height),
         {:ok, crop_width} <- crop_dimension(crop.width, image_width),
         {:ok, crop_height} <- crop_dimension(crop.height, image_height),
         {crop_width, crop_height} =
           correct_aspect_ratio(crop_width, crop_height, params.aspect_ratio, params.enlarge, image_width, image_height),
         {:ok, {cropped, _attention}} <-
           Vix.Vips.Operation.smartcrop(state.image, crop_width, crop_height, interesting: interesting) do
      {:ok, set_image(state, cropped)}
    else
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
```

(`Vix.Vips.Operation.smartcrop/4` returns `{:ok, {image, %{attention_x: _, attention_y: _}}}`. Confirm the exact opt key/value with `mise exec -- mix run -e 'IO.inspect(Vix.Vips.Operation.smartcrop(Image.open!("<fixture>"), 50, 50, interesting: :VIPS_INTERESTING_ATTENTION))'` before relying on it.)

- [ ] **Step 4: Run — expect pass**

Run: `mise exec -- mix test test/image_pipe/transform/operation/crop_test.exs`
Expected: PASS.

- [ ] **Step 5: Add a behavioral (non-golden) test**

Add a test asserting attention differs from a centered crop on an off-center fixture (pick a fixture with a clearly off-center subject; compare the smart crop's bytes to a `{:anchor, :center, :center}` crop of the same size and assert they are **not** equal — robust to libvips version):

```elixir
test "smart crop differs from a centered crop on an off-center subject" do
  image = Image.open!("test/support/fixtures/<off-center-fixture>.png")
  state = %ImagePipe.Transform.State{image: image}
  base = %ImagePipe.Transform.Operation.Crop{width: {:pixels, 80}, height: {:pixels, 80}, crop_from: :gravity}

  {:ok, %{image: smart}} = ImagePipe.Transform.Operation.Crop.execute(%{base | gravity: :smart}, state)
  {:ok, %{image: center}} = ImagePipe.Transform.Operation.Crop.execute(%{base | gravity: {:anchor, :center, :center}}, state)

  refute Image.write!(smart, :memory, suffix: ".png") == Image.write!(center, :memory, suffix: ".png")
end
```

(If no suitably off-center fixture exists, add one to `test/support/fixtures` and note it.)

- [ ] **Step 6: Run — expect pass; commit**

Run: `mise exec -- mix test test/image_pipe/transform/operation/crop_test.exs`
Expected: PASS.

```bash
git add lib/image_pipe/transform/operation/crop.ex test/image_pipe/transform/operation/crop_test.exs
git commit -m "feat(transform): smart-crop via libvips attention for :smart gravity"
```

---

### Task 5: Parser — `g:sm` → `:smart` (remove rejections, map in builder)

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex:196-200,648-665`
- Test: `test/image_pipe/parser/imgproxy/plan_builder_test.exs` (or the existing parser test file)

- [ ] **Step 1: Write failing planner tests**

In the imgproxy planner/parser test file, add (adapt to how the suite builds a `ParsedRequest` / calls `to_plan` — reuse existing helpers):

```elixir
test "g:sm maps to a :smart resize guide" do
  {:ok, plan} = parse_to_plan("rs:fill:100:100/g:sm/plain/http://example.com/x.png")
  resize = Enum.find(hd(plan.pipelines).operations, &match?(%ImagePipe.Plan.Operation.Resize{}, &1))
  assert resize.guide == :smart
end

test "c:100:100:sm maps to a :smart crop guide" do
  {:ok, plan} = parse_to_plan("c:100:100:sm/plain/http://example.com/x.png")
  crop = Enum.find(hd(plan.pipelines).operations, &match?(%ImagePipe.Plan.Operation.CropGuided{}, &1))
  assert crop.guide == :smart
end
```

(Use the suite's real end-to-end parse helper; the URL form above is illustrative.)

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/parser/imgproxy/`
Expected: FAIL — currently `{:error, {:unsupported_gravity, :sm}}`.

- [ ] **Step 3: Remove the `:sm` rejections**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, delete the two `reject_unsupported_semantics` clauses at lines 196-197 and 199-200 (keep the `%PipelineRequest{}` catch-all `:ok` clause at line 202).

- [ ] **Step 4: Map `:sm` in the guide translators**

In the same file, add `:sm` clauses to `resize_guide/1` (after line 648) and `tagged_gravity/1` (after line 658):

```elixir
  defp resize_guide(:sm), do: {:ok, :smart}
```
```elixir
  defp tagged_gravity(:sm), do: {:ok, :smart}
```

- [ ] **Step 5: Run — expect pass**

Run: `mise exec -- mix test test/image_pipe/parser/imgproxy/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/plan_builder.ex test/image_pipe/parser/imgproxy/
git commit -m "feat(parser): map imgproxy g:sm to the :smart plan guide"
```

---

### Task 6: Wire-level plug test for `g:sm`

**Files:**
- Test: `test/image_pipe/parser/imgproxy/<existing wire-level plug test>.exs`

- [ ] **Step 1: Write the end-to-end test**

Add a test that issues a real `ImagePipe.call/2` for a `g:sm` URL and asserts the decoded output dimensions and that the body differs from a centered crop (reuse the suite's existing conn/sign helpers and source fixture):

```elixir
test "g:sm returns a smart-cropped image of the requested size" do
  conn = signed_get("rs:fill:80:80/g:sm")
  conn = ImagePipe.call(conn, @opts)
  assert conn.status == 200
  {:ok, out} = Image.from_binary(conn.resp_body)
  assert Image.width(out) == 80 and Image.height(out) == 80
end
```

- [ ] **Step 2: Run — expect pass; commit**

Run: `mise exec -- mix test <that file>`
Expected: PASS.

```bash
git add test/image_pipe/parser/imgproxy/
git commit -m "test(imgproxy): wire-level g:sm smart crop"
```

---

### Task 7: Demo + matrix for Phase 1, then gate

**Files:**
- Modify: `demo/` imgproxy gravity controls + URL state
- Modify: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Add `sm` to the demo gravity control**

In the `demo/` Svelte app, add `sm` as a gravity option in the imgproxy controls and URL state. Find the gravity control (search `demo/` for `gravity` / `g:`), add the `sm` choice, and ensure it round-trips in the URL.

- [ ] **Step 2: Update the matrix**

In `docs/imgproxy_support_matrix.md`: flip the `gravity:sm` row to ✅ (remove "Planning rejects parsed smart gravity"); rewrite the `crop` row's "Planning rejects smart gravity" sentence.

- [ ] **Step 3: Gate**

Run: `mise run precommit:demo`
Expected: format/compile/credo/test + demo verify all pass.

- [ ] **Step 4: Commit**

```bash
git add demo/ docs/imgproxy_support_matrix.md
git commit -m "docs+demo: expose g:sm smart crop"
```

**Phase 1 complete — `g:sm` smart crop ships.**

---

# PHASE 2 — `Detector` seam + `g:obj:face`

### Task 8: The `Detector` behaviour

**Files:**
- Create: `lib/image_pipe/transform/detector.ex`
- Modify: `lib/image_pipe/transform.ex:14-36` (exports)

- [ ] **Step 1: Create the behaviour**

```elixir
defmodule ImagePipe.Transform.Detector do
  @moduledoc """
  Host-implementable content detection for content-aware gravity.

  Detectors translate image content into product-neutral regions. The default
  adapter wraps the optional `image_vision` dependency; hosts may inject their
  own. Return values cross a host boundary and are validated structurally by the
  caller (`ImagePipe.Transform.Operation.Crop`).
  """

  @type region :: %{
          label: String.t(),
          score: float(),
          box: {number(), number(), number(), number()}
        }

  @doc "Detect regions of interest. `opts` carries `:classes`."
  @callback detect(image :: Vix.Vips.Image.t(), opts :: keyword()) ::
              {:ok, [region()]} | {:error, term()}

  @doc "Whether the detector can run now (e.g. the optional dependency is loaded)."
  @callback available?(opts :: keyword()) :: boolean()

  @doc "Stable identity for cache-key material."
  @callback identity(opts :: keyword()) :: {module(), term()}

  @doc "Optionally pre-load models so the first request avoids download cost."
  @callback warmup(opts :: keyword()) :: :ok | {:error, term()}
  @optional_callbacks warmup: 1
end
```

- [ ] **Step 2: Export from the transform boundary**

In `lib/image_pipe/transform.ex`, add `Detector` to the `exports:` list (after `Materializer`).

- [ ] **Step 3: Compile + commit**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

```bash
git add lib/image_pipe/transform/detector.ex lib/image_pipe/transform.ex
git commit -m "feat(transform): add product-neutral Detector behaviour"
```

---

### Task 9: A test double + structural return validation in `Crop`

**Files:**
- Create: `test/support/fake_detector.ex`
- Modify: `lib/image_pipe/transform/state.ex`
- Modify: `lib/image_pipe/transform/operation/crop.ex`
- Test: `test/image_pipe/transform/operation/crop_test.exs`

- [ ] **Step 1: Create the DI fake detector**

```elixir
defmodule ImagePipe.Test.FakeDetector do
  @moduledoc "Configurable in-memory Detector for deterministic tests."
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def detect(_image, opts) do
    case Keyword.fetch(opts, :result) do
      {:ok, result} -> result
      :error -> {:ok, []}
    end
  end

  @impl true
  def available?(opts), do: Keyword.get(opts, :available?, true)

  @impl true
  def identity(opts), do: {__MODULE__, Keyword.get(opts, :identity, :fake_v1)}
end
```

Ensure `test/support` is compiled (it is, via the project's `elixirc_paths` for `:test`).

- [ ] **Step 2: Add detector fields to `State`**

In `lib/image_pipe/transform/state.ex`, update the moduledoc to note injected runtime config, then change the struct/type:

```elixir
  defstruct image: nil,
            debug: false,
            detector: nil,
            detector_required: false

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t() | nil,
          debug: boolean(),
          detector: module() | nil,
          detector_required: boolean()
        }
```

- [ ] **Step 3: Write failing detect-path tests**

Add to `crop_test.exs`:

```elixir
describe "detect gravity" do
  setup do
    {:ok, image: Image.open!("test/support/fixtures/<fixture>.png")}
  end

  test "anchors on the area-weighted centroid of detected boxes", %{image: image} do
    state = %ImagePipe.Transform.State{image: image, detector: {ImagePipe.Test.FakeDetector, [result: {:ok, [%{label: "face", score: 0.9, box: {0, 0, 10, 10}}]}]}}
    op = %ImagePipe.Transform.Operation.Crop{width: {:pixels, 40}, height: {:pixels, 40}, crop_from: :gravity, gravity: {:detect, ["face"]}}
    assert {:ok, %{image: out}} = ImagePipe.Transform.Operation.Crop.execute(op, state)
    assert Image.width(out) == 40
  end

  test "no detections falls back to attention", %{image: image} do
    state = %ImagePipe.Transform.State{image: image, detector: {ImagePipe.Test.FakeDetector, [result: {:ok, []}]}}
    op = %ImagePipe.Transform.Operation.Crop{width: {:pixels, 40}, height: {:pixels, 40}, crop_from: :gravity, gravity: {:detect, ["face"]}}
    assert {:ok, %{image: out}} = ImagePipe.Transform.Operation.Crop.execute(op, state)
    assert Image.width(out) == 40
  end

  test "out-of-image box is dropped, falls back to attention", %{image: image} do
    state = %ImagePipe.Transform.State{image: image, detector: {ImagePipe.Test.FakeDetector, [result: {:ok, [%{label: "face", score: 0.9, box: {-50, -50, 5, 5}}]}]}}
    op = %ImagePipe.Transform.Operation.Crop{width: {:pixels, 40}, height: {:pixels, 40}, crop_from: :gravity, gravity: {:detect, ["face"]}}
    assert {:ok, %{image: _}} = ImagePipe.Transform.Operation.Crop.execute(op, state)
  end

  test "detector error falls back to attention (graceful)", %{image: image} do
    state = %ImagePipe.Transform.State{image: image, detector: {ImagePipe.Test.FakeDetector, [result: {:error, :boom}]}}
    op = %ImagePipe.Transform.Operation.Crop{width: {:pixels, 40}, height: {:pixels, 40}, crop_from: :gravity, gravity: {:detect, ["face"]}}
    assert {:ok, %{image: _}} = ImagePipe.Transform.Operation.Crop.execute(op, state)
  end

  test "nil detector falls back to attention", %{image: image} do
    state = %ImagePipe.Transform.State{image: image, detector: nil}
    op = %ImagePipe.Transform.Operation.Crop{width: {:pixels, 40}, height: {:pixels, 40}, crop_from: :gravity, gravity: {:detect, ["face"]}}
    assert {:ok, %{image: _}} = ImagePipe.Transform.Operation.Crop.execute(op, state)
  end
end
```

Note: `state.detector` is `{module, opts}` (module + per-request opts) so the fake can be parameterized. Real config passes the bare module; the executor wraps it as `{module, []}` (Task 12). Keep both shapes by normalizing in `Crop`.

- [ ] **Step 4: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/transform/operation/crop_test.exs`
Expected: FAIL — `{:detect, _}` unhandled.

- [ ] **Step 5: Implement the detect branch + validation + fallback**

In `crop.ex`, add a clause to `execute/2` (above the generic clause) and helpers:

```elixir
  def execute(%__MODULE__{gravity: {:detect, classes}} = params, %State{} = state) do
    detect_crop(params, state, classes)
  end
```

Add helpers near `smart_crop/3`:

```elixir
  defp detect_crop(%__MODULE__{} = params, %State{} = state, classes) do
    {module, dopts} = normalize_detector(state.detector)

    cond do
      is_nil(module) ->
        smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)

      true ->
        case run_detect(module, dopts, state.image, classes) do
          {:ok, [_ | _] = regions} ->
            case focal_from_regions(regions, image_width(state), image_height(state)) do
              {:ok, fp} -> execute(%{params | gravity: fp}, state)
              :none -> smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
            end

          _ ->
            smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
        end
    end
  end

  defp normalize_detector(nil), do: {nil, []}
  defp normalize_detector(module) when is_atom(module), do: {module, []}
  defp normalize_detector({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}

  defp run_detect(module, opts, image, classes) do
    case module.detect(image, Keyword.put(opts, :classes, classes)) do
      {:ok, regions} when is_list(regions) ->
        if Enum.all?(regions, &valid_region?/1), do: {:ok, regions}, else: {:error, {:detector, :invalid_adapter_result}}

      {:error, _} = error ->
        error

      _other ->
        {:error, {:detector, :invalid_adapter_result}}
    end
  end

  defp valid_region?(%{box: {x, y, w, h}}) when is_number(x) and is_number(y) and is_number(w) and is_number(h), do: true
  defp valid_region?(_), do: false

  # Area-weighted centroid of in-image boxes, normalized to 0.0..1.0.
  defp focal_from_regions(regions, image_width, image_height) do
    in_image =
      Enum.filter(regions, fn %{box: {x, y, w, h}} ->
        w > 0 and h > 0 and x >= 0 and y >= 0 and x + w <= image_width and y + h <= image_height
      end)

    case in_image do
      [] ->
        :none

      boxes ->
        total = Enum.reduce(boxes, 0.0, fn %{box: {_x, _y, w, h}}, acc -> acc + w * h end)

        {sx, sy} =
          Enum.reduce(boxes, {0.0, 0.0}, fn %{box: {x, y, w, h}}, {ax, ay} ->
            area = w * h
            {ax + area * (x + w / 2), ay + area * (y + h / 2)}
          end)

        {:ok, {:fp, clamp_unit(sx / total / image_width), clamp_unit(sy / total / image_height)}}
    end
  end

  defp clamp_unit(v), do: v |> max(0.0) |> min(1.0)
```

`{:fp, x, y}` then flows through the existing focal crop path (re-entering `execute/2`).

- [ ] **Step 6: Run — expect pass; commit**

Run: `mise exec -- mix test test/image_pipe/transform/operation/crop_test.exs`
Expected: PASS.

```bash
git add lib/image_pipe/transform/state.ex lib/image_pipe/transform/operation/crop.ex test/support/fake_detector.ex test/image_pipe/transform/operation/crop_test.exs
git commit -m "feat(transform): detect-gravity branch with centroid anchor + fallback ladder"
```

---

### Task 10: `ImageVision` adapter (optional dependency)

**Files:**
- Create: `lib/image_pipe/transform/detector/image_vision.ex`
- Modify: `mix.exs`
- Test: `test/image_pipe/transform/detector/image_vision_test.exs`

- [ ] **Step 1: Create the adapter**

```elixir
defmodule ImagePipe.Transform.Detector.ImageVision do
  @moduledoc """
  Default `ImagePipe.Transform.Detector` backed by the optional `image_vision`
  dependency. Faces use `Image.FaceDetection` (YuNet); the dependency is not
  declared by ImagePipe — hosts opt in. When absent, `available?/1` is false and
  callers fall back gracefully.
  """
  @behaviour ImagePipe.Transform.Detector

  @compile {:no_warn_undefined, Image.FaceDetection}

  @repo "opencv/face_detection_yunet"
  @model_file "face_detection_yunet_2023mar.onnx"

  @impl true
  def available?(_opts), do: Code.ensure_loaded?(Image.FaceDetection)

  @impl true
  def identity(_opts) do
    if available?([]), do: {__MODULE__, {@repo, @model_file}}, else: {__MODULE__, :unavailable}
  end

  @impl true
  def detect(image, opts) do
    classes = Keyword.get(opts, :classes, [])

    cond do
      not available?(opts) -> {:error, {:detector, :unavailable}}
      classes != ["face"] -> {:error, {:detector, {:unsupported_classes, classes}}}
      true -> detect_faces(image)
    end
  end

  @impl true
  def warmup(opts) do
    if available?(opts) do
      {:ok, blank} = Image.new(64, 64, color: :black)
      _ = detect_faces(blank)
      :ok
    else
      {:error, {:detector, :unavailable}}
    end
  end

  # Image.FaceDetection.detect/1 returns a BARE list of
  # %{box: {x,y,w,h}, score, landmarks} and RAISES on failure — wrap in a narrow
  # boundary rescue (this is the sanctioned host/optional-dep runtime boundary).
  defp detect_faces(image) do
    regions =
      image
      |> Image.FaceDetection.detect()
      |> Enum.map(fn %{box: box, score: score} -> %{label: "face", score: score, box: box} end)

    {:ok, regions}
  rescue
    error -> {:error, {:detector, error}}
  end
end
```

- [ ] **Step 2: Add the env-gated optional dependency**

In `mix.exs`, in `deps/0`, append conditionally:

```elixir
  defp deps do
    base = [ ... existing deps ... ]
    if System.get_env("IMAGE_VISION") in ["1", "true"], do: base ++ [{:image_vision, "~> 0.4", only: :test}], else: base
  end
```

Run `mise exec -- mix deps.get` (without the env var — unchanged). For the opt-in lane: `IMAGE_VISION=1 mise exec -- mix deps.get`.

- [ ] **Step 3: Write adapter tests (dep-absent path)**

```elixir
defmodule ImagePipe.Transform.Detector.ImageVisionTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Detector.ImageVision

  test "available? mirrors Code.ensure_loaded?(Image.FaceDetection)" do
    assert ImageVision.available?([]) == Code.ensure_loaded?(Image.FaceDetection)
  end

  @tag :image_vision
  test "detect returns face regions when the dependency is present" do
    image = Image.open!("test/support/fixtures/<portrait-fixture>.png")
    assert {:ok, regions} = ImageVision.detect(image, classes: ["face"])
    assert Enum.all?(regions, &match?(%{label: "face", box: {_, _, _, _}}, &1))
  end

  test "identity reflects availability" do
    expected = if ImageVision.available?([]), do: {ImageVision, {"opencv/face_detection_yunet", "face_detection_yunet_2023mar.onnx"}}, else: {ImageVision, :unavailable}
    assert ImageVision.identity([]) == expected
  end
end
```

Exclude `:image_vision` by default — in `test/test_helper.exs` add `ExUnit.start(exclude: [:image_vision])`.

- [ ] **Step 4: Run — expect pass; commit**

Run: `mise exec -- mix test test/image_pipe/transform/detector/image_vision_test.exs`
Expected: PASS (the `@tag :image_vision` test is skipped without the dep).

```bash
git add lib/image_pipe/transform/detector/image_vision.ex mix.exs test/image_pipe/transform/detector/image_vision_test.exs test/test_helper.exs
git commit -m "feat(transform): ImageVision detector adapter (optional dep, gated tests)"
```

---

### Task 11: `Plan.detect_classes/1` accessor

**Files:**
- Modify: `lib/image_pipe/plan.ex`
- Test: `test/image_pipe/plan_test.exs`

- [ ] **Step 1: Write a failing test**

```elixir
test "detect_classes finds a {:detect, classes} guide anywhere in the plan" do
  plan = %ImagePipe.Plan{pipelines: [%ImagePipe.Plan.Pipeline{operations: [%ImagePipe.Plan.Operation.CropGuided{width: {:px, 1}, height: {:px, 1}, guide: {:detect, ["face"]}}]}]}
  assert ImagePipe.Plan.detect_classes(plan) == ["face"]
end

test "detect_classes is nil when no detect guide is present" do
  plan = %ImagePipe.Plan{pipelines: [%ImagePipe.Plan.Pipeline{operations: [%ImagePipe.Plan.Operation.CropGuided{width: {:px, 1}, height: {:px, 1}, guide: :center}]}]}
  assert ImagePipe.Plan.detect_classes(plan) == nil
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/plan_test.exs`
Expected: FAIL — undefined function.

- [ ] **Step 3: Implement the accessor**

In `lib/image_pipe/plan.ex` add (it owns the canonical request model; it may read `CropGuided`/`Resize` guide fields generically):

```elixir
  @doc "Returns the detect-guide classes if any operation requests detection, else nil."
  @spec detect_classes(t()) :: [String.t()] | nil
  def detect_classes(%__MODULE__{pipelines: pipelines}) do
    pipelines
    |> Enum.flat_map(& &1.operations)
    |> Enum.find_value(fn op ->
      case Map.get(op, :guide) do
        {:detect, classes} -> classes
        _ -> nil
      end
    end)
  end
```

- [ ] **Step 4: Run — expect pass; commit**

Run: `mise exec -- mix test test/image_pipe/plan_test.exs`
Expected: PASS.

```bash
git add lib/image_pipe/plan.ex test/image_pipe/plan_test.exs
git commit -m "feat(plan): detect_classes/1 accessor for content-aware gravity"
```

---

### Task 12: Thread detector config plug → executor → State

**Files:**
- Modify: `lib/image_pipe/plug.ex` (options + opts passing)
- Modify: `lib/image_pipe/transform/plan_executor.ex`
- Modify: wherever `%State{image: image}` is built and `execute_plan/3` is called (the `Processor`/runner)

- [ ] **Step 1: Add validated plug options**

In `lib/image_pipe/plug.ex`, add `detector` and `detector_required` to the options schema (the `Options.validate!` path). Default `detector: :default`, `detector_required: false`. Resolve `:default`/`nil` to `ImagePipe.Transform.Detector.ImageVision` **inside the transform boundary** — i.e. pass the option value through to `execute_plan/3` opts unchanged; the executor resolves it (next step), so `plug.ex` never names the concrete adapter.

- [ ] **Step 2: Populate State in the executor**

In `lib/image_pipe/transform/plan_executor.ex`, in `execute/3`, resolve and set the detector before running pipelines:

```elixir
  def execute(%Plan{pipelines: pipelines}, %State{} = state, opts) do
    state = %{
      state
      | detector: resolve_detector(Keyword.get(opts, :detector, :default)),
        detector_required: Keyword.get(opts, :detector_required, false)
    }

    execute_pipelines(pipelines, state, opts)
  end

  defp resolve_detector(:default), do: ImagePipe.Transform.Detector.ImageVision
  defp resolve_detector(nil), do: nil
  defp resolve_detector(module) when is_atom(module), do: module
```

(This keeps `Processor`'s `%State{image: image}` construction detector-free — the executor owns population.)

- [ ] **Step 3: Forward the options from the request layer**

Ensure the request/runner passes `:detector` and `:detector_required` from plug opts into the `execute_plan/3`/`Transform.execute_plan` opts. Trace from `plug.ex` opts → `Processor` → `Transform.execute_plan`. Add the two keys to whatever opts subset is forwarded.

- [ ] **Step 4: Compile + existing suite**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test`
Expected: clean + green (no behavior change yet for default builds — `ImageVision.available?` is false without the dep, so `{:detect,_}` would fall back to attention; but no plan emits `{:detect,_}` until Task 13).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/plug.ex lib/image_pipe/transform/plan_executor.ex lib/image_pipe/request/
git commit -m "feat(runtime): thread detector config into transform State"
```

---

### Task 13: Parser — `g:obj:face` → `{:detect, ["face"]}`; reject the rest

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex`
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex`
- Test: parser tests

- [ ] **Step 1: Write failing parser tests**

```elixir
test "g:obj:face maps to a {:detect, [\"face\"]} guide" do
  {:ok, plan} = parse_to_plan("rs:fill:100:100/g:obj:face/plain/http://example.com/x.png")
  resize = Enum.find(hd(plan.pipelines).operations, &match?(%ImagePipe.Plan.Operation.Resize{}, &1))
  assert resize.guide == {:detect, ["face"]}
end

test "c:100:100:obj:face maps to a {:detect, [\"face\"]} crop guide" do
  {:ok, plan} = parse_to_plan("c:100:100:obj:face/plain/http://example.com/x.png")
  crop = Enum.find(hd(plan.pipelines).operations, &match?(%ImagePipe.Plan.Operation.CropGuided{}, &1))
  assert crop.guide == {:detect, ["face"]}
end

test "bare g:obj is rejected (means 'all')" do
  assert {:error, {:unsupported_gravity, _}} = parse_to_plan("rs:fill:100:100/g:obj/plain/http://example.com/x.png")
end

for variant <- ["obj:all", "obj:face:cat", "objw:face:2"] do
  test "g:#{variant} is rejected" do
    assert {:error, _} = parse_to_plan("rs:fill:100:100/g:#{unquote(variant)}/plain/http://example.com/x.png")
  end
end

test "g:obj:face:5:5 is rejected (5 is not a face class)" do
  assert {:error, _} = parse_to_plan("rs:fill:100:100/g:obj:face:5:5/plain/http://example.com/x.png")
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/parser/imgproxy/`
Expected: FAIL.

- [ ] **Step 3: Parse `obj` tails in the grammar**

In `lib/image_pipe/parser/imgproxy/option_grammar.ex`:

Add an `obj` clause to `parse_gravity/2` (before the `[anchor]` clause at line 860):

```elixir
  defp parse_gravity(["obj" | classes], _segment),
    do: {:ok, [gravity: {:obj, classes}, gravity_x_offset: {:pixels, 0.0}, gravity_y_offset: {:pixels, 0.0}]}
```

Add an `obj` clause to `parse_crop_gravity/1` (before the `[anchor]` clause at line 796):

```elixir
  defp parse_crop_gravity(["obj" | classes]), do: {:ok, {:obj, classes}}
```

Add a variadic `obj`-tail clause to `parse_crop/2` (before the catch-all at line 770):

```elixir
  defp parse_crop([width, height, "obj" | classes], _segment)
       when width != "" and height != "" do
    with {:ok, width} <- parse_crop_dimension(width),
         {:ok, height} <- parse_crop_dimension(height),
         {:ok, gravity} <- parse_crop_gravity(["obj" | classes]) do
      {:ok, [crop: %CropRequest{width: width, height: height, gravity: gravity}]}
    end
  end
```

(`obj` is intentionally **not** added to `@gravity_anchors`, preserving the `extend`/`extend_ar` exclusion which routes solely through `parse_gravity_anchor/1`.)

- [ ] **Step 4: Map / reject in the builder**

In `plan_builder.ex`, add clauses to `resize_guide/1` and `tagged_gravity/1`:

```elixir
  defp resize_guide({:obj, ["face"]}), do: {:ok, {:detect, ["face"]}}
  defp resize_guide({:obj, classes}), do: {:error, {:unsupported_gravity, {:obj, classes}}}
```
```elixir
  defp tagged_gravity({:obj, ["face"]}), do: {:ok, {:detect, ["face"]}}
  defp tagged_gravity({:obj, classes}), do: {:error, {:unsupported_gravity, {:obj, classes}}}
```

(Bare `g:obj` parses to `{:obj, []}` → not `["face"]` → rejected. `obj:face:5:5` parses to `{:obj, ["face","5","5"]}` → rejected.)

- [ ] **Step 5: Run — expect pass; commit**

Run: `mise exec -- mix test test/image_pipe/parser/imgproxy/`
Expected: PASS.

```bash
git add lib/image_pipe/parser/imgproxy/option_grammar.ex lib/image_pipe/parser/imgproxy/plan_builder.ex test/image_pipe/parser/imgproxy/
git commit -m "feat(parser): g:obj:face -> {:detect,[\"face\"]}, reject other obj forms"
```

---

### Task 14: Strict-mode pre-fetch gate

**Files:**
- Modify: `lib/image_pipe/plug.ex` (`do_call/1`, alongside `validate_client_plan/1`)
- Test: a wire-level plug test

- [ ] **Step 1: Write a failing wire test**

```elixir
test "detector_required + unavailable detector rejects before source/cache access" do
  {:ok, agent} = Agent.start_link(fn -> [] end)  # or use the suite's source/cache spies
  opts = ImagePipe.init(@base_opts ++ [detector: UnavailableDetector, detector_required: true])
  conn = ImagePipe.call(signed_get("rs:fill:80:80/g:obj:face"), opts)
  assert conn.status in 400..499
  # assert no Source.resolve / no [:cache, :lookup] telemetry fired (use the suite's spy helpers)
end
```

Define a tiny `UnavailableDetector` in the test that implements `available?(_) -> false`, `detect/2`, `identity/2`.

- [ ] **Step 2: Run — expect failure (currently 200, falls back to attention)**

Run: `mise exec -- mix test <that file>`
Expected: FAIL.

- [ ] **Step 3: Add the gate in `do_call/1`**

In `lib/image_pipe/plug.ex`, after `validate_client_plan/1` resolves the plan and before source resolve, add a check that uses the validated plan and the configured detector:

```elixir
  defp detector_capability_ok(plan, opts) do
    if Keyword.get(opts, :detector_required, false) and ImagePipe.Plan.detect_classes(plan) != nil do
      detector = resolve_detector(Keyword.get(opts, :detector, :default))
      if detector && detector.available?(opts), do: :ok, else: {:error, {:detector, :unavailable}}
    else
      :ok
    end
  end
```

Wire it into the `with` chain in `do_call/1` so a `{:error, {:detector, :unavailable}}` returns the appropriate error response **before** `Source.resolve`/`Runner.run`. Reuse the same `resolve_detector/1` logic (extract a shared helper if needed). Read the guide via `ImagePipe.Plan.detect_classes/1` — do **not** pattern-match `CropGuided`.

- [ ] **Step 4: Run — expect pass; commit**

Run: `mise exec -- mix test <that file>`
Expected: PASS.

```bash
git add lib/image_pipe/plug.ex test/image_pipe/
git commit -m "feat(runtime): strict-mode detector pre-fetch gate"
```

---

### Task 15: Cache key — fold in detector identity

**Files:**
- Modify: `lib/image_pipe/cache.ex` (`@plan_key_option_keys`, `key_options/2`)
- Modify: `lib/image_pipe/cache/key.ex` (`build/4` / `plan_material/2`)
- Modify: the request layer that calls `Cache.lookup` (inject the identity tuple)
- Test: `test/image_pipe/cache/key_test.exs`

- [ ] **Step 1: Write failing cache-key tests**

```elixir
test "detect plans key differently per detector identity" do
  plan = detect_face_plan()  # builds a Plan with a {:detect,["face"]} guide
  k1 = ImagePipe.Cache.Key.build(plan, source, [detector_identity: {Mod, :v1}], [])
  k2 = ImagePipe.Cache.Key.build(plan, source, [detector_identity: {Mod, :v2}], [])
  assert k1 != k2
end

test "unavailable identity keys differently from a present one" do
  plan = detect_face_plan()
  present = ImagePipe.Cache.Key.build(plan, source, [detector_identity: {Mod, {"r", "f"}}], [])
  absent = ImagePipe.Cache.Key.build(plan, source, [detector_identity: {Mod, :unavailable}], [])
  assert present != absent
end
```

(Match `Cache.Key.build/4`'s real arity/argument order — adjust to the signature in `key.ex`.)

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/cache/key_test.exs`
Expected: FAIL — identity not in the key.

- [ ] **Step 3: Allowlist + read the identity**

In `lib/image_pipe/cache.ex`, add `:detector_identity` to `@plan_key_option_keys`. In `lib/image_pipe/cache/key.ex`, in the `plan_material/2` keyword list folded into `Key.build`, add:

```elixir
  detector: Keyword.get(opts, :detector_identity),
```

so the opaque `{module, term}` tuple (or `nil`) participates in the key.

- [ ] **Step 4: Inject the identity conditionally at the request layer**

Where the request layer builds the `opts` passed to `Cache.lookup` (the runner), conditionally inject:

```elixir
  defp put_detector_identity(opts, plan) do
    detector = resolve_detector(Keyword.get(opts, :detector, :default))

    cond do
      is_nil(detector) -> opts
      ImagePipe.Plan.detect_classes(plan) != nil or face_assist?(plan) ->
        Keyword.put(opts, :detector_identity, detector.identity(opts))
      true -> opts
    end
  end
```

`face_assist?/1` checks the plan for a `{:smart, :face_assist}` guide (mirror `detect_classes/1`; add `Plan.face_assist?/1` in Task 19). For Phase 2, `face_assist?` can be `false`; wire it fully in Phase 3.

- [ ] **Step 5: Run — expect pass; commit**

Run: `mise exec -- mix test test/image_pipe/cache/key_test.exs && mise exec -- mix test`
Expected: PASS + green.

```bash
git add lib/image_pipe/cache.ex lib/image_pipe/cache/key.ex lib/image_pipe/request/ test/image_pipe/cache/key_test.exs
git commit -m "feat(cache): include detector identity in key for detection plans"
```

---

### Task 16: `[:transform, :detect]` telemetry span

**Files:**
- Modify: `lib/image_pipe/transform/operation/crop.ex` (wrap the `detect/2` call)
- Modify: `lib/image_pipe/telemetry/logger.ex` (register the event)
- Test: `test/image_pipe/transform/operation/crop_test.exs` (attach a handler)

- [ ] **Step 1: Write a failing telemetry test**

```elixir
test "detection emits a [:transform, :detect] span with safe metadata", %{image: image} do
  ref = :telemetry_test.attach_event_handlers(self(), [[:transform, :detect, :stop]])
  state = %ImagePipe.Transform.State{image: image, detector: {ImagePipe.Test.FakeDetector, [result: {:ok, [%{label: "face", score: 0.9, box: {0, 0, 10, 10}}]}]}}
  op = %ImagePipe.Transform.Operation.Crop{width: {:pixels, 40}, height: {:pixels, 40}, crop_from: :gravity, gravity: {:detect, ["face"]}}
  {:ok, _} = ImagePipe.Transform.Operation.Crop.execute(op, state)
  assert_receive {[:transform, :detect, :stop], ^ref, %{duration: _}, metadata}
  refute Map.has_key?(metadata, :source_url)
  :telemetry.detach(ref)
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/transform/operation/crop_test.exs`
Expected: FAIL — no span.

- [ ] **Step 3: Wrap the detect call in a span**

In `crop.ex`'s `run_detect/4`, wrap the `module.detect(...)` call in the project's telemetry span helper (find it in `lib/image_pipe/telemetry.ex`; it's `:telemetry.span/3`-style). Metadata: `%{classes: classes}` plus result region count/boxes — **never** URLs/keys/paths.

- [ ] **Step 4: Register in the default logger**

In `lib/image_pipe/telemetry/logger.ex`, add `[:transform, :detect]` to the `transform:` group event list.

- [ ] **Step 5: Run — expect pass; commit**

Run: `mise exec -- mix test test/image_pipe/transform/operation/crop_test.exs`
Expected: PASS.

```bash
git add lib/image_pipe/transform/operation/crop.ex lib/image_pipe/telemetry/logger.ex test/image_pipe/transform/operation/crop_test.exs
git commit -m "feat(telemetry): honest [:transform,:detect] span for ML detection"
```

---

### Task 17: Architecture boundary tests

**Files:**
- Modify: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Add `Detector*` to the forbidden-reference set**

Add `Detector`, `Detector.ImageVision`, `Detector.Warmup` to the concrete-name list that request/source/response/cache must not reference, mirroring `@concrete_transform_names`.

- [ ] **Step 2: Extend the request/source/response globs to cover `plug.ex`**

Add `lib/image_pipe/plug.ex` to `@request_source_response_globs` so the strict gate is forced to use `Plan.detect_classes/1` rather than naming `CropGuided`.

- [ ] **Step 3: Add a producer test for no dialect leak**

In the imgproxy planner test file (not the arch test — this is a producer test), assert the builder never emits a `{:obj, _}` or `:sm` guide:

```elixir
test "planner never emits dialect gravity terms" do
  for url <- ["rs:fill:50:50/g:sm", "rs:fill:50:50/g:obj:face", "c:50:50:sm", "c:50:50:obj:face"] do
    {:ok, plan} = parse_to_plan(url <> "/plain/http://example.com/x.png")
    guides = for p <- plan.pipelines, op <- p.operations, g = Map.get(op, :guide), do: g
    refute Enum.any?(guides, &match?({:obj, _}, &1))
    refute Enum.any?(guides, &(&1 == :sm))
  end
end
```

- [ ] **Step 4: Run — expect pass; commit**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs test/image_pipe/parser/imgproxy/`
Expected: PASS.

```bash
git add test/image_pipe/architecture_boundary_test.exs test/image_pipe/parser/imgproxy/
git commit -m "test(arch): forbid concrete detector refs; cover plug.ex; no dialect leak"
```

---

### Task 18: Phase 2 demo + matrix + gate

**Files:**
- Modify: `demo/`, `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Demo** — add an `obj:face` gravity option to the imgproxy controls + URL state.

- [ ] **Step 2: Matrix** — add a `gravity:obj:face` ✅ row; **downgrade `gravity:obj` to ⚠️ Partial** ("face only; bare `obj`/`all`/multi/`objw` rejected"); **replace** the blanket `IMGPROXY_OBJECT_DETECTION_*` wildcard ⭕ line with broken-out rows for `IMGPROXY_OBJECT_DETECTION_GRAVITY_MODE`, `…_FALLBACK_TO_SMART_CROP`, and confidence/NMS thresholds, each ⭕ with a note. Add the model/gravity-mode divergence notes from the spec's Divergences §.

- [ ] **Step 3: Gate + commit**

Run: `mise run precommit:demo`
Expected: green.

```bash
git add demo/ docs/imgproxy_support_matrix.md
git commit -m "docs+demo: expose g:obj:face; matrix object-detection breakdown"
```

**Phase 2 complete — face-aware gravity ships (graceful without the dep).**

---

# PHASE 3 — face-assist blend (`smart_crop_face_detection`)

### Task 19: `Plan.face_assist?/1` + config threading in the parser

**Files:**
- Modify: `lib/image_pipe/plan.ex` (`face_assist?/1`)
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex` (read `smart_crop_face_detection`, thread to guide translators)
- Test: parser + plan tests

- [ ] **Step 1: Write failing tests**

```elixir
test "face_assist? detects a {:smart, :face_assist} guide" do
  plan = %ImagePipe.Plan{pipelines: [%ImagePipe.Plan.Pipeline{operations: [%ImagePipe.Plan.Operation.Resize{guide: {:smart, :face_assist}}]}]}
  assert ImagePipe.Plan.face_assist?(plan)
end

test "g:sm with smart_crop_face_detection becomes {:smart, :face_assist}" do
  {:ok, plan} = parse_to_plan("rs:fill:100:100/g:sm/plain/http://example.com/x.png", imgproxy: [smart_crop_face_detection: true])
  resize = Enum.find(hd(plan.pipelines).operations, &match?(%ImagePipe.Plan.Operation.Resize{}, &1))
  assert resize.guide == {:smart, :face_assist}
end

test "g:sm without the flag stays :smart" do
  {:ok, plan} = parse_to_plan("rs:fill:100:100/g:sm/plain/http://example.com/x.png")
  resize = Enum.find(hd(plan.pipelines).operations, &match?(%ImagePipe.Plan.Operation.Resize{}, &1))
  assert resize.guide == :smart
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/parser/imgproxy/ test/image_pipe/plan_test.exs`
Expected: FAIL.

- [ ] **Step 3: Add `Plan.face_assist?/1`**

```elixir
  @spec face_assist?(t()) :: boolean()
  def face_assist?(%__MODULE__{pipelines: pipelines}) do
    Enum.any?(pipelines, fn p ->
      Enum.any?(p.operations, &(Map.get(&1, :guide) == {:smart, :face_assist}))
    end)
  end
```

- [ ] **Step 4: Thread the config flag through the builder**

`to_plan/2` already has `opts`. Thread `Keyword.get(Keyword.get(opts, :imgproxy, []), :smart_crop_face_detection, false)` down to `pipeline/1` → `plan_geometry/1` → `resize_operations`/`crop_operations` → `resize_guide`/`tagged_gravity`. The least-invasive route: carry the flag in a small build-context value passed alongside the request, or set it on a field the translators read. Concretely, pass `face_assist?` as a second argument to `resize_guide/2` and `tagged_gravity/2`:

```elixir
  defp resize_guide(:sm, true), do: {:ok, {:smart, :face_assist}}
  defp resize_guide(:sm, _), do: {:ok, :smart}
  # ...thread the same bool to existing clauses (default the bool to false)...
```

Add the validated `smart_crop_face_detection` boolean to the imgproxy parser options (`Imgproxy.validate_options!`), default `false`.

- [ ] **Step 5: Run — expect pass; commit**

Run: `mise exec -- mix test test/image_pipe/parser/imgproxy/ test/image_pipe/plan_test.exs`
Expected: PASS.

```bash
git add lib/image_pipe/plan.ex lib/image_pipe/parser/imgproxy/ test/
git commit -m "feat(parser): smart_crop_face_detection -> {:smart,:face_assist} guide"
```

---

### Task 20: Face-assist blend execution

**Files:**
- Modify: `lib/image_pipe/transform/operation/crop.ex`
- Test: `test/image_pipe/transform/operation/crop_test.exs`

- [ ] **Step 1: Write a failing test**

```elixir
test "face_assist blends attention with the face centroid", %{image: image} do
  # A fake face far to one corner; assert the blended crop differs from BOTH
  # pure attention and a pure-centroid detect crop.
  fake = {ImagePipe.Test.FakeDetector, [result: {:ok, [%{label: "face", score: 0.9, box: {0, 0, 6, 6}}]}]}
  state = %ImagePipe.Transform.State{image: image, detector: fake}
  base = %ImagePipe.Transform.Operation.Crop{width: {:pixels, 60}, height: {:pixels, 60}, crop_from: :gravity}

  {:ok, %{image: assist}} = ImagePipe.Transform.Operation.Crop.execute(%{base | gravity: {:smart, :face_assist}}, state)
  {:ok, %{image: smart}} = ImagePipe.Transform.Operation.Crop.execute(%{base | gravity: :smart}, state)
  png = fn img -> Image.write!(img, :memory, suffix: ".png") end
  refute png.(assist) == png.(smart)
end

test "face_assist with nil detector falls back to pure attention", %{image: image} do
  state = %ImagePipe.Transform.State{image: image, detector: nil}
  op = %ImagePipe.Transform.Operation.Crop{width: {:pixels, 60}, height: {:pixels, 60}, crop_from: :gravity, gravity: {:smart, :face_assist}}
  assert {:ok, %{image: _}} = ImagePipe.Transform.Operation.Crop.execute(op, state)
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/transform/operation/crop_test.exs`
Expected: FAIL — `{:smart, :face_assist}` unhandled.

- [ ] **Step 3: Implement the blend**

Add an `execute/2` clause and helper to `crop.ex`:

```elixir
  def execute(%__MODULE__{gravity: {:smart, :face_assist}} = params, %State{} = state) do
    {module, dopts} = normalize_detector(state.detector)

    with false <- is_nil(module),
         {:ok, [_ | _] = regions} <- run_detect(module, dopts, state.image, ["face"]),
         {:ok, {:fp, fx, fy}} <- focal_from_regions(regions, image_width(state), image_height(state)),
         {:ok, {ax, ay}} <- attention_point(params, state) do
      w = 0.7
      blended = {:fp, clamp_unit((1 - w) * ax + w * fx), clamp_unit((1 - w) * ay + w * fy)}
      execute(%{params | gravity: blended}, state)
    else
      _ -> smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    end
  end
```

Add `attention_point/2`, which runs `smartcrop` only to read the chosen point and normalizes it:

```elixir
  defp attention_point(%__MODULE__{} = params, %State{} = state) do
    image_width = image_width(state)
    image_height = image_height(state)

    with {:ok, crop} <- crop_dimensions(params, image_width, image_height),
         {:ok, crop_width} <- crop_dimension(crop.width, image_width),
         {:ok, crop_height} <- crop_dimension(crop.height, image_height),
         {crop_width, crop_height} =
           correct_aspect_ratio(crop_width, crop_height, params.aspect_ratio, params.enlarge, image_width, image_height),
         {:ok, {_cropped, %{attention_x: ax, attention_y: ay}}} <-
           Vix.Vips.Operation.smartcrop(state.image, crop_width, crop_height, interesting: :VIPS_INTERESTING_ATTENTION) do
      {:ok, {clamp_unit(ax / image_width), clamp_unit(ay / image_height)}}
    end
  end
```

(Confirm `attention_x`/`attention_y` are returned in pixels of the input image with the same probe command from Task 4 Step 3. `w = 0.7` is the documented face-favoring weight; keep it as a module attribute `@face_assist_weight 0.7`.)

- [ ] **Step 4: Run — expect pass; commit**

Run: `mise exec -- mix test test/image_pipe/transform/operation/crop_test.exs`
Expected: PASS.

```bash
git add lib/image_pipe/transform/operation/crop.ex test/image_pipe/transform/operation/crop_test.exs
git commit -m "feat(transform): face-assist blend of attention point and face centroid"
```

---

### Task 21: Cache distinctness + demo + matrix for face-assist

**Files:**
- Modify: request layer `put_detector_identity/2` (wire `face_assist?` true now)
- Test: `test/image_pipe/cache/key_test.exs`
- Modify: `demo/`, `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Wire `face_assist?` into identity injection**

In the `put_detector_identity/2` from Task 15 Step 4, replace the `face_assist?` stub with `ImagePipe.Plan.face_assist?(plan)`.

- [ ] **Step 2: Write + run a cache test**

```elixir
test "face_assist dep-present vs dep-absent do not collide" do
  plan = face_assist_plan()
  present = ImagePipe.Cache.Key.build(plan, source, [detector_identity: {Mod, {"r", "f"}}], [])
  absent = ImagePipe.Cache.Key.build(plan, source, [detector_identity: {Mod, :unavailable}], [])
  assert present != absent
end
```

Run: `mise exec -- mix test test/image_pipe/cache/key_test.exs` → PASS.

- [ ] **Step 3: Demo + matrix**

Demo: add a `smart_crop_face_detection` toggle to the imgproxy controls. Matrix: mark `IMGPROXY_SMART_CROP_FACE_DETECTION` ✅ (config) with a divergence marker; ensure the `IMGPROXY_SMART_CROP_*` wildcard row is replaced/broken out per the spec.

- [ ] **Step 4: Gate + commit**

Run: `mise run precommit:demo`

```bash
git add lib/image_pipe/request/ test/image_pipe/cache/key_test.exs demo/ docs/imgproxy_support_matrix.md
git commit -m "feat: face-assist cache distinctness + demo/matrix"
```

**Phase 3 complete — face-assisted smart crop ships.**

---

# PHASE 4 — eager warmup worker

### Task 22: `Detector.warmup/2` helper

**Files:**
- Modify: `lib/image_pipe/transform/detector.ex`
- Test: `test/image_pipe/transform/detector_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
defmodule ImagePipe.Transform.DetectorTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Detector

  defmodule WithWarmup do
    @behaviour Detector
    def detect(_i, _o), do: {:ok, []}
    def available?(_o), do: true
    def identity(_o), do: {__MODULE__, :v}
    def warmup(opts), do: send(Keyword.fetch!(opts, :test_pid), {:warmed, opts}) && :ok
  end

  defmodule NoWarmup do
    @behaviour Detector
    def detect(_i, _o), do: {:ok, []}
    def available?(_o), do: true
    def identity(_o), do: {__MODULE__, :v}
  end

  test "calls warmup/1 when implemented" do
    assert Detector.warmup(WithWarmup, test_pid: self()) == :ok
    assert_receive {:warmed, _}
  end

  test "is a no-op when warmup/1 is not implemented" do
    assert Detector.warmup(NoWarmup, []) == :ok
  end
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/transform/detector_test.exs`
Expected: FAIL — undefined.

- [ ] **Step 3: Implement the helper**

In `lib/image_pipe/transform/detector.ex`:

```elixir
  @doc "Invoke the optional warmup/1 callback if the detector implements it."
  @spec warmup(module(), keyword()) :: :ok | {:error, term()}
  def warmup(module, opts) when is_atom(module) do
    # Host-boundary optional callback (same pattern as Cache.validate_options);
    # the presence check is sanctioned here, not internal duck-typing.
    if function_exported?(module, :warmup, 1), do: module.warmup(opts), else: :ok
  end
```

- [ ] **Step 4: Run — expect pass; commit**

Run: `mise exec -- mix test test/image_pipe/transform/detector_test.exs`
Expected: PASS.

```bash
git add lib/image_pipe/transform/detector.ex test/image_pipe/transform/detector_test.exs
git commit -m "feat(transform): Detector.warmup/2 host-boundary helper"
```

---

### Task 23: `Detector.Warmup` worker

**Files:**
- Create: `lib/image_pipe/transform/detector/warmup.ex`
- Modify: `lib/image_pipe/transform.ex` (export `Detector.Warmup`)
- Test: `test/image_pipe/transform/detector/warmup_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
defmodule ImagePipe.Transform.Detector.WarmupTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Detector.Warmup

  defmodule SignalDetector do
    @behaviour ImagePipe.Transform.Detector
    def detect(_i, _o), do: {:ok, []}
    def available?(_o), do: true
    def identity(_o), do: {__MODULE__, :v}
    def warmup(opts) do
      pid = Keyword.fetch!(opts, :test_pid)
      send(pid, {:warm_started, Keyword.get(opts, :classes)})
      receive do
        :release -> :ok
      after
        2_000 -> :ok
      end
    end
  end

  test "async warmup does not block start and terminates :normal" do
    pid = start_supervised!({Warmup, detector: SignalDetector, classes: ["face"], mode: :async, opts: [test_pid: self()]})
    ref = Process.monitor(pid)
    assert_receive {:warm_started, ["face"]}     # warmup ran (off init path)
    send(pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "unavailable detector is a clean no-op that still terminates" do
    pid = start_supervised!({Warmup, detector: ImagePipe.Transform.Detector.ImageVision, classes: ["face"], mode: :async, opts: []})
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
```

- [ ] **Step 2: Run — expect failure**

Run: `mise exec -- mix test test/image_pipe/transform/detector/warmup_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the worker**

```elixir
defmodule ImagePipe.Transform.Detector.Warmup do
  @moduledoc """
  Optional one-shot worker that pre-loads a detector's models at boot. Host-wired:
  add to the host's supervision tree. Transient (loads once, terminates :normal).
  Does NOT trap exits — a shutdown mid-download is acceptable (nothing staged).
  """
  use GenServer, restart: :transient
  require Logger

  alias ImagePipe.Transform.Detector

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      detector: Keyword.fetch!(opts, :detector),
      classes: Keyword.get(opts, :classes, ["face"]),
      opts: Keyword.get(opts, :opts, []),
      retries: Keyword.get(opts, :retries, 2)
    }

    case Keyword.get(opts, :mode, :async) do
      :sync -> {:ok, state, {:continue, :warm_then_stop}}
      :async -> {:ok, state, {:continue, :warm_then_stop}}
    end
  end

  @impl true
  def handle_continue(:warm_then_stop, state) do
    warm(state, state.retries)
    {:stop, :normal, state}
  end

  defp warm(_state, retries) when retries < 0, do: :ok

  defp warm(state, retries) do
    case Detector.warmup(state.detector, Keyword.put(state.opts, :classes, state.classes)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("detector warmup failed (#{inspect(reason)}), #{retries} retries left")
        warm(state, retries - 1)
    end
  end
end
```

(Both `:sync` and `:async` use `{:continue, ...}` — `start_link` returns once `init` returns, so neither blocks the host supervisor's *boot*; `:sync` is reserved for a future variant that loads in `init`. Keep the `mode` option for forward-compat; document that `:async` is the default and non-blocking.)

- [ ] **Step 4: Export + run + commit**

Add `Detector.Warmup` to `transform.ex` `exports:`.

Run: `mise exec -- mix test test/image_pipe/transform/detector/warmup_test.exs`
Expected: PASS.

```bash
git add lib/image_pipe/transform/detector/warmup.ex lib/image_pipe/transform.ex test/image_pipe/transform/detector/warmup_test.exs
git commit -m "feat(transform): optional Detector.Warmup worker"
```

---

### Task 24: Final gate + docs

- [ ] **Step 1: Full gate**

Run: `mise run precommit:demo`
Expected: format/compile-warnings-as-errors/credo/test + demo verify all pass.

- [ ] **Step 2: Opt-in ML lane sanity (optional, local)**

Run: `IMAGE_VISION=1 mise exec -- mix deps.get && IMAGE_VISION=1 mise exec -- mix test --only image_vision`
Expected: the real-dep tests run and pass (downloads YuNet on first run).

- [ ] **Step 3: Spec status + commit**

Update the spec status line to `accepted` and reference this plan.

```bash
git add docs/superpowers/specs/2026-05-30-smart-gravity-design.md
git commit -m "docs: mark smart-gravity spec accepted"
```

---

## Self-Review (author checklist — completed)

**Spec coverage:** `:smart` (T1-4), cache serialization (T2), parser g:sm (T5) + g:obj:face + rejections (T13), Detector behaviour (T8) + ImageVision adapter (T10) + DI fake + validation + fallback ladder incl. nil/bogus-box (T9), State threading (T12), Plan.detect_classes (T11), strict gate (T14), cache identity incl. availability (T15, T21), telemetry span + logger (T16), arch tests incl. plug.ex glob + no-dialect-leak producer (T17), face-assist config + blend + cache distinctness (T19-21), warmup helper + worker (T22-23), demo + matrix per phase (T7, T18, T21), env-gated dep + excluded tag (T10). Divergences land in the matrix (T18, T21).

**Placeholders:** none — `<fixture>` markers are explicit "pick a real fixture" instructions, not code placeholders; every code step shows the code.

**Type consistency:** guide variants `:smart` / `{:smart, :face_assist}` / `{:detect, [String.t()]}` consistent across plan type (T1), key_data (T2), executor (T3), crop (T4/T9/T20), parser (T5/T13/T19), accessors (T11/T19). `Detector` callbacks `detect/2`, `available?/1`, `identity/1`, `warmup/1` consistent across behaviour (T8), adapter (T10), fake (T9), helper (T22), worker (T23). `state.detector` normalized to `{module, opts}` in `Crop` (T9) while config passes a bare module resolved in the executor (T12) — `normalize_detector/1` handles both.

**Open verification flags for the implementer (do these first in the relevant task):** confirm `Vix.Vips.Operation.smartcrop/4` opt key (`:interesting`) and return shape `{:ok, {image, %{attention_x, attention_y}}}` (T4 Step 3 probe); confirm `Operation.crop_guided`/`resize` constructors accept the new guides (T1 Step 3); confirm `Cache.Key.build/4` argument order (T15); confirm `Image.FaceDetection.detect/1` return shape against the installed `image_vision` (T10, gated).
