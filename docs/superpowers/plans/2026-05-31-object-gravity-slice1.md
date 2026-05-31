# General Object Gravity (Slice 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend ImagePipe's content-aware gravity from the single-class `face` subset to imgproxy's general object gravity (`g:obj`, `g:obj:all`, `g:obj:%c1:…:%cN` and the `c:W:H:obj…` crop forms), backed by a product-neutral Composite detector that routes face classes to YuNet and COCO classes to RT-DETR and merges the regions.

**Architecture:** A new `Detector.Composite` holds an ordered child list `[ImageVision.Face, ImageVision.Objects]`, routes a requested class set per child via a new `supported_classes/1` behaviour callback, fans out, and merges regions. The plan carries a product-neutral `{:detect, :all} | {:detect, [classes]}` guide; the imgproxy parser normalizes `all`/bare-`obj` to `:all` and stays vocabulary-free. Cache identity and the strict gate become class-aware by threading the plan's detect classes into the detector opts. The equal-weight `area` centroid is unchanged (per-class weights are Slice 2).

**Tech Stack:** Elixir, `image_vision 0.4.0` (`Image.FaceDetection` YuNet + `Image.Detection` RT-DETR/COCO-80, via `ortex`), `Vix`/`Image` (libvips), `:telemetry`, `NimbleOptions`, ExUnit + StreamData.

**Reference spec:** `docs/superpowers/specs/2026-05-31-object-gravity-slice1-design.md`

**Run everything via `mise exec -- …`** (e.g. `mise exec -- mix test path`). The Elixir gate is `mise run precommit`; the demo gate is `mise run precommit:demo`.

**ML-dependency lane:** the real models require `image_vision`/`ortex` + a model download. Tests that exercise the real model are tagged `@tag :image_vision` and excluded by default; all deterministic tests inject a fake detector. Run tagged tests with `IMAGE_VISION=1 mise exec -- mix test --only image_vision` only when explicitly verifying the live adapters.

---

## File structure

**New files:**
- `lib/image_pipe/transform/detector/image_vision/face.ex` — YuNet face adapter (moved from the current `image_vision.ex`, + `supported_classes/1`).
- `lib/image_pipe/transform/detector/image_vision/objects.ex` — RT-DETR/COCO-80 object adapter.
- `lib/image_pipe/transform/detector/composite.ex` — ordered-child router/merger; emits per-model spans.

**Deleted:**
- `lib/image_pipe/transform/detector/image_vision.ex` — replaced by `image_vision/face.ex`.

**Modified:**
- `lib/image_pipe/transform/detector.ex` — add `@callback supported_classes/1`.
- `lib/image_pipe/transform.ex:76` — `@default_detector` → `Composite`.
- `lib/image_pipe/plan/operation/crop_guided.ex` — guide type `+ {:detect, :all}`.
- `lib/image_pipe/transform/operation/crop.ex` — gravity type `+ {:detect, :all}`; `run_detect` threads `:telemetry_opts`.
- `lib/image_pipe/plan.ex:88-99` — `detect_classes/1` `@spec` widened to `:all | nonempty_list | nil`.
- `lib/image_pipe/plan/key_data.ex:198` — add `guide_data({:detect, :all})`.
- `lib/image_pipe/parser/imgproxy/plan_builder.ex:664-667` — `tagged_gravity/2` multi-class/`:all` mapping.
- `lib/image_pipe/request/runner.ex:238-247` — thread classes into `detector_identity`.
- `lib/image_pipe/plug.ex:143-151` — thread classes into the strict gate.
- `lib/image_pipe/transform/detector/warmup.ex` — default `classes: :all`; moduledoc.
- `test/image_pipe/architecture_boundary_test.exs` — extend detector-reference scan to parser/plan.
- `docs/content-aware-gravity.md`, `docs/imgproxy_support_matrix.md`, `docs/telemetry.md` — docs.
- `demo/` — object-class controls + URL state.

**Test files (created/extended) — exact paths:**
- `test/image_pipe/transform/detector/composite_test.exs` (new)
- `test/image_pipe/transform/detector/image_vision_test.exs` (rename refs; tagged Objects smoke/drift)
- `test/parser/imgproxy/plan_builder_test.exs` (flip rejection → acceptance) — note `test/parser/…`, **not** `test/image_pipe/parser/…`
- `test/image_pipe/cache/key_test.exs` (class-aware key material via `build_key!/4`)
- `test/image_pipe/imgproxy_wire_conformance_test.exs` (pixel + gate triad)
- `test/image_pipe/transform/crop_operation_test.exs` (FakeDetector `supported_classes`) — note: `transform/`, **not** `transform/operation/`
- `test/image_pipe/plan/operation_key_data_test.exs` (`{:detect, :all}` guide encoding)
- `test/support/fake_detector.ex`, `test/image_pipe/transform/detector_test.exs`, `test/image_pipe/transform/detector/warmup_test.exs` (add `supported_classes/1` to their fakes — see Task 1)

### Test harness reference (READ BEFORE WRITING ANY TEST)

The plan's test snippets are illustrative; **bind them to the harness that actually exists** (verified in plan review). Do not invent helpers:

- **Wire tests** (`imgproxy_wire_conformance_test.exs`): drive with `call_imgproxy(path, opts, accept \\ nil)` (returns a `conn`); read `conn.status` / `conn.resp_body`; decode dimensions with `dimensions(conn)` (which uses `decoded_image/1`). Source is the hardcoded `"plain/images/beach.jpg"` (there is **no** `source_url/0`/`request/2`/`wire_opts/1`/`decoded_dimensions/1`). Inject a detector via `Keyword.merge(@default_opts, detector: SomeModule, detector_required: …)`. Assert "no source fetch" with the existing `OriginShouldNotFetch` plug + inline `refute_received :origin_fetch` (plus the telemetry/cache `refute_received` it already uses) — there is **no** `assert_no_source_fetch/1`. The existing test `"detector_required + unavailable detector rejects before source AND cache access"` (~line 541) is the template for the 422 pre-fetch leg; the `g:sm` pixel test is the template for decode-and-compare.
- **Parser tests** (`test/parser/imgproxy/plan_builder_test.exs`): drive the planner with `plan_pipeline(keyword_attrs, opts)` over `%ParsedRequest{}`/`%PipelineRequest{}`/`%CropRequest{}` and read `resize.guide` / `crop.guide` directly. There is **no** `build/1` or `detect_guide/1` URL-string helper.
- **Cache-key tests** (`cache/key_test.exs`): call `build_key!(conn, plan, source_identity(), detector_identity: {Detector, :v1})` — the identity tuple is passed **literally**; `Cache.Key.build` does **not** resolve a detector (forbidden by the architecture test). Build plans via the planner / `Operation.crop_guided/4`, not hand-built structs.
- **Key-data tests** (`plan/operation_key_data_test.exs`): `KeyData.data(%CropGuided{…})` on struct literals (sanctioned in this file).
- **Telemetry tests**: attach with `:telemetry_test.attach_event_handlers(self(), [[:image_pipe, :transform, :detect, :model, :stop]])` (note the `:image_pipe` prefix). Runtime `telemetry_opts` is `[telemetry_prefix: [:image_pipe]]` (the key is `:telemetry_prefix`, not `:prefix`); `Telemetry.span/4` is `(telemetry_opts, stage, start_meta, fun)` with `fun` returning `{value, stop_meta}`.
- **FakeDetector**: the shared `ImagePipe.Test.FakeDetector` (`test/support/fake_detector.ex`) is the canonical injected fake (used across `crop_operation_test.exs`); extend it rather than hand-rolling where it fits.

---

## Task 1: Add `supported_classes/1` to the Detector behaviour

**Files (verified in plan review — every implementer must gain the callback in THIS commit or `--warnings-as-errors` fails):**
- Modify: `lib/image_pipe/transform/detector.ex` (add the callback)
- Modify: `lib/image_pipe/transform/detector/image_vision.ex` (prod adapter → `["face"]`; renamed in Task 2)
- Modify: `test/support/fake_detector.ex` — `ImagePipe.Test.FakeDetector` (the shared fake; note it may not use `@impl`)
- Modify: `test/image_pipe/transform/detector_test.exs` — fakes `WithWarmup` **and** `NoWarmup`
- Modify: `test/image_pipe/transform/detector/warmup_test.exs` — fakes `SignalDetector` **and** `UnavailableDetector`
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs` — fake `UnavailableDetector`

That is **6 fake modules across 5 files** plus the prod adapter. `mix compile --warnings-as-errors` treats a missing required callback as a failure.

- [ ] **Step 1: Confirm the full implementer list**

Run: `grep -rl "@behaviour ImagePipe.Transform.Detector" lib test`
Expected: the 5 files above. Open each and note that `detector_test.exs` and `warmup_test.exs` define **two** fakes each — every module gets `supported_classes/1`, not just one per file.

- [ ] **Step 2: Add the callback to the behaviour**

In `lib/image_pipe/transform/detector.ex`, after the `detect/2` callback block (around line 26), add:

```elixir
  @doc """
  The class names this detector can produce, in the URL-facing spelling.

  Static metadata used to route a requested class set to detectors and to gate
  availability — it MUST NOT load a model and MUST be answerable even when the
  detector's optional dependency is absent (so a routing/availability decision
  can be made without the dep). `available?/1` may be `false` while this still
  returns the full vocabulary.
  """
  @callback supported_classes(opts :: keyword()) :: [String.t()]
```

- [ ] **Step 3: Implement it in the current `ImageVision` adapter**

In `lib/image_pipe/transform/detector/image_vision.ex`, add after `available?/1`:

```elixir
  @impl true
  def supported_classes(_opts), do: ["face"]
```

- [ ] **Step 4: Implement it in every test fake found in Step 1**

For each fake, add a `supported_classes/1` returning the classes that fake claims (a face fake returns `["face"]`; a generic fake returns whatever labels its canned regions use). Example for a fake that returns `face` regions:

```elixir
  @impl true
  def supported_classes(_opts), do: ["face"]
```

If a fake is parameterized (returns configurable regions), make `supported_classes/1` return the labels it is configured to emit, or a fixed superset the test controls.

- [ ] **Step 5: Compile with warnings-as-errors**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: PASS, no "function supported_classes/1 required by behaviour … is not implemented" warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/transform/detector.ex lib/image_pipe/transform/detector/image_vision.ex test
git commit -m "feat(detector): add supported_classes/1 behaviour callback"
```

---

## Task 2: Rename the face adapter to `ImageVision.Face`

Mostly a mechanical move so the bundled adapters are symmetric siblings (`ImageVision.Face` / `ImageVision.Objects`) under the Composite. It also makes one deliberate behavior change to `detect/2` (called out below and tested): it accepts `classes == :all` (returns faces) and returns `{:ok, []}` for any other routed class instead of the old `{:error, {:detector, {:unsupported_classes, …}}}` — because the Composite never routes non-face classes here, and `:all` legitimately asks this child for faces. The face *detection* behavior (`["face"]` → faces) is unchanged.

**Files:**
- Create: `lib/image_pipe/transform/detector/image_vision/face.ex`
- Delete: `lib/image_pipe/transform/detector/image_vision.ex`
- Modify: `lib/image_pipe/transform.ex:76` (`@default_detector`)
- Modify: references in `test/image_pipe/transform/detector/image_vision_test.exs`, `lib/image_pipe/transform/detector/warmup.ex` moduledoc, and any cache-key test naming the identity tuple

- [ ] **Step 1: Create the renamed module**

Create `lib/image_pipe/transform/detector/image_vision/face.ex` as the current `image_vision.ex` content with the module renamed to `ImagePipe.Transform.Detector.ImageVision.Face`. Keep the YuNet logic, `@repo`/`@model_file`, `detect/2`, `available?/1`, `warmup/1`, and `supported_classes(_) -> ["face"]`. Update `identity/1` to fold `min_score` into the tuple for forward-consistency with the Objects adapter (min_score is a fixed default here):

```elixir
defmodule ImagePipe.Transform.Detector.ImageVision.Face do
  @moduledoc """
  `ImagePipe.Transform.Detector` for faces, backed by the optional `image_vision`
  dependency (`Image.FaceDetection`, YuNet). The dependency is not declared by
  ImagePipe — hosts opt in. When absent, `available?/1` is false and callers fall
  back gracefully.
  """
  @behaviour ImagePipe.Transform.Detector

  @compile {:no_warn_undefined, Image.FaceDetection}

  @repo "opencv/face_detection_yunet"
  @model_file "face_detection_yunet_2023mar.onnx"

  @impl true
  def supported_classes(_opts), do: ["face"]

  @impl true
  def available?(_opts), do: Code.ensure_loaded?(Image.FaceDetection)

  @impl true
  def identity(_opts) do
    if available?([]),
      do: {__MODULE__, {@repo, @model_file}},
      else: {__MODULE__, :unavailable}
  end

  @impl true
  def detect(image, opts) do
    classes = Keyword.get(opts, :classes, [])

    cond do
      not available?(opts) -> {:error, {:detector, :unavailable}}
      classes == :all or classes == ["face"] -> detect_faces(image)
      true -> {:ok, []}
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

Note two changes vs the old module: `detect/2` now accepts `classes == :all` (returns faces) and returns `{:ok, []}` for any other routed class instead of an `{:unsupported_classes, …}` error (the Composite never routes non-face classes here, and `:all` legitimately asks for faces).

- [ ] **Step 2: Delete the old module**

```bash
git rm lib/image_pipe/transform/detector/image_vision.ex
```

- [ ] **Step 3: Repoint `@default_detector`**

In `lib/image_pipe/transform.ex:76`:

```elixir
  @default_detector ImagePipe.Transform.Detector.ImageVision.Face
```

(This is temporary — Task 5 repoints it to the Composite. Pointing at `.Face` now keeps the face path working between tasks.)

- [ ] **Step 4: Update references in tests and docs**

In `test/image_pipe/transform/detector/image_vision_test.exs` and any cache-key test, replace `ImagePipe.Transform.Detector.ImageVision` with `…ImageVision.Face`. Update the `warmup.ex` moduledoc example's `classes: ["face"]` is still valid; no code change required there yet.

Run: `mise exec -- grep -rn "Detector.ImageVision\b" lib test docs` and fix any remaining bare `ImageVision` references that should be `ImageVision.Face`.

- [ ] **Step 5: Add tests for the new `detect/2` arms**

In `test/image_pipe/transform/detector/image_vision_test.exs`, add (default lane — no dep needed, since both assertions hit the `available?` short-circuit when the dep is absent):

```elixir
  alias ImagePipe.Transform.Detector.ImageVision.Face

  test "Face.detect with :all short-circuits to unavailable when the dep is absent" do
    # In the default (no image_vision) lane, available? is false, so any classes
    # value returns the unavailable error rather than crashing.
    assert {:error, {:detector, :unavailable}} = Face.detect(:image, classes: :all)
    assert {:error, {:detector, :unavailable}} = Face.detect(:image, classes: ["car"])
  end
```

And a tagged assertion (dep present) that `:all` returns faces and a non-face routed class returns `{:ok, []}`:

```elixir
  describe "Face.detect routing (real model)" do
    @describetag :image_vision

    test "classes: :all returns faces; a non-face routed class returns no regions" do
      {:ok, image} = Image.new(64, 64, color: :black)
      assert {:ok, regions} = Face.detect(image, classes: :all)
      assert is_list(regions)
      assert {:ok, []} = Face.detect(image, classes: ["car"])
    end
  end
```

- [ ] **Step 6: Compile + run the face/detector tests**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/image_pipe/transform/detector/`
Expected: PASS (face detection behavior unchanged; new `detect/2` arms covered).

- [ ] **Step 7: Commit**

```bash
git add -A lib/image_pipe/transform lib/image_pipe/transform.ex test docs
git commit -m "feat(detector): rename ImageVision -> ImageVision.Face; detect/2 accepts :all"
```

---

## Task 3: `ImageVision.Objects` adapter (RT-DETR / COCO-80)

**Files:**
- Create: `lib/image_pipe/transform/detector/image_vision/objects.ex`
- Test: `test/image_pipe/transform/detector/image_vision_test.exs` (add a tagged smoke + drift test)

- [ ] **Step 1: Write the failing drift + smoke test (tagged)**

Add to `test/image_pipe/transform/detector/image_vision_test.exs`:

```elixir
  alias ImagePipe.Transform.Detector.ImageVision.Objects

  # supported_classes is a hardcoded static list (dep-independent), so this runs
  # in the DEFAULT lane — it is the deterministic coverage for the underscore
  # spelling that the normalization depends on.
  describe "Objects vocabulary (no dependency required)" do
    test "supported_classes is the static COCO-80 vocabulary in underscore spelling" do
      classes = Objects.supported_classes([])
      assert "person" in classes
      assert "traffic_light" in classes
      refute "traffic light" in classes
      assert length(classes) == 80
    end
  end

  describe "Objects adapter (real model)" do
    @describetag :image_vision

    test "supported_classes matches the model's labels (drift guard)" do
      model_labels =
        Image.Detection.classes()
        |> Enum.map(&String.replace(&1, " ", "_"))
        |> Enum.sort()

      assert Enum.sort(Objects.supported_classes([])) == model_labels
    end

    test "detect returns product-neutral regions on a synthetic image" do
      {:ok, image} = Image.new(320, 240, color: :black)
      assert {:ok, regions} = Objects.detect(image, classes: :all)
      assert is_list(regions)
      assert Enum.all?(regions, &match?(%{label: l, score: _, box: {_, _, _, _}} when is_binary(l), &1))
    end
  end
```

- [ ] **Step 2: Run it to verify it fails**

Default lane (runs the non-tagged vocabulary test):
Run: `mise exec -- mix test test/image_pipe/transform/detector/image_vision_test.exs`
Expected: FAIL — `Objects` is undefined.

- [ ] **Step 3: Implement the Objects adapter**

Create `lib/image_pipe/transform/detector/image_vision/objects.ex`. The COCO-80 list is hardcoded in underscore spelling (dep-independent). `detect/2` calls `Image.Detection.detect/2` with `min_score`, normalizes the model's space-spelled labels to underscores, and filters to the routed classes (or returns all for `:all`).

```elixir
defmodule ImagePipe.Transform.Detector.ImageVision.Objects do
  @moduledoc """
  `ImagePipe.Transform.Detector` for general objects, backed by the optional
  `image_vision` dependency (`Image.Detection`, RT-DETR, COCO-80). The dependency
  is not declared by ImagePipe — hosts opt in. When absent, `available?/1` is
  false and callers fall back gracefully.

  Class names use the URL-facing underscore spelling (`traffic_light`); the model
  emits spaces (`"traffic light"`), which this adapter normalizes on both sides.
  """
  @behaviour ImagePipe.Transform.Detector

  @compile {:no_warn_undefined, Image.Detection}

  @repo "onnx-community/rtdetr_r50vd"
  @filename "onnx/model.onnx"
  @min_score 0.5

  # COCO-80, underscore spelling. Hardcoded (not derived from Image.Detection)
  # so routing/availability work when the dependency is absent. A tagged drift
  # test asserts this matches the model's labels.
  @coco_classes ~w(
    person bicycle car motorcycle airplane bus train truck boat traffic_light
    fire_hydrant stop_sign parking_meter bench bird cat dog horse sheep cow
    elephant bear zebra giraffe backpack umbrella handbag tie suitcase frisbee
    skis snowboard sports_ball kite baseball_bat baseball_glove skateboard
    surfboard tennis_racket bottle wine_glass cup fork knife spoon bowl banana
    apple sandwich orange broccoli carrot hot_dog pizza donut cake chair couch
    potted_plant bed dining_table toilet tv laptop mouse remote keyboard
    cell_phone microwave oven toaster sink refrigerator book clock vase scissors
    teddy_bear hair_drier toothbrush
  )

  @impl true
  def supported_classes(_opts), do: @coco_classes

  @impl true
  def available?(_opts), do: Code.ensure_loaded?(Image.Detection)

  @impl true
  def identity(_opts) do
    if available?([]),
      do: {__MODULE__, {@repo, @filename, @min_score}},
      else: {__MODULE__, :unavailable}
  end

  @impl true
  def detect(image, opts) do
    classes = Keyword.get(opts, :classes, :all)

    if available?(opts),
      do: detect_objects(image, classes),
      else: {:error, {:detector, :unavailable}}
  end

  @impl true
  def warmup(opts) do
    if available?(opts) do
      {:ok, blank} = Image.new(64, 64, color: :black)
      _ = detect_objects(blank, :all)
      :ok
    else
      {:error, {:detector, :unavailable}}
    end
  end

  defp detect_objects(image, classes) do
    regions =
      image
      |> Image.Detection.detect(min_score: @min_score, repo: @repo, filename: @filename)
      |> Enum.map(fn %{label: label, score: score, box: box} ->
        %{label: String.replace(label, " ", "_"), score: score, box: box}
      end)
      |> filter_classes(classes)

    {:ok, regions}
  rescue
    error -> {:error, {:detector, error}}
  end

  defp filter_classes(regions, :all), do: regions

  defp filter_classes(regions, classes) when is_list(classes) do
    wanted = MapSet.new(classes)
    Enum.filter(regions, fn %{label: label} -> MapSet.member?(wanted, label) end)
  end
end
```

- [ ] **Step 4: Run both lanes to verify they pass**

Default lane (vocabulary): `mise exec -- mix test test/image_pipe/transform/detector/image_vision_test.exs`
Tagged lane (drift + smoke, needs the dep + model download): `IMAGE_VISION=1 mise exec -- mix test test/image_pipe/transform/detector/image_vision_test.exs --include image_vision`
Expected: PASS in both.

- [ ] **Step 5: Compile with warnings-as-errors**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/transform/detector/image_vision/objects.ex test/image_pipe/transform/detector/image_vision_test.exs
git commit -m "feat(detector): add ImageVision.Objects RT-DETR/COCO-80 adapter"
```

---

## Task 4: `Detector.Composite` — routing, merge, identity, availability

The Composite is a plain `Detector` module with a fixed child list. Routing, merge, class-aware identity, and class-aware availability all derive from the children's `supported_classes/1`. Per-model telemetry spans are added in Task 9 — keep `detect/2` free of telemetry for now.

**Files:**
- Create: `lib/image_pipe/transform/detector/composite.ex`
- Test: `test/image_pipe/transform/detector/composite_test.exs` (new) — driven by **fake child detectors**, not hand-built region lists.

- [ ] **Step 1: Write the failing Composite tests with fake children**

Create `test/image_pipe/transform/detector/composite_test.exs`:

```elixir
defmodule ImagePipe.Transform.Detector.CompositeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Detector.Composite

  # Fake children: each owns a vocabulary and returns one canned region per
  # routed class (label = class). Real @behaviour producers, so this is not an
  # impossible-internal-misuse test.
  defmodule FaceChild do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_), do: ["face"]
    @impl true
    def available?(opts), do: Keyword.get(opts, :face_available?, true)
    @impl true
    def identity(_), do: {__MODULE__, :face_v1}
    @impl true
    def detect(_image, opts), do: {:ok, regions_for(opts)}
    defp regions_for(opts) do
      requested(opts, ["face"])
      |> Enum.map(&%{label: &1, score: 0.9, box: {0, 0, 10, 10}})
    end
    defp requested(opts, owned) do
      case Keyword.get(opts, :classes, :all) do
        :all -> owned
        list -> Enum.filter(list, &(&1 in owned))
      end
    end
  end

  defmodule ObjectChild do
    @behaviour ImagePipe.Transform.Detector
    @owned ["car", "dog"]
    @impl true
    def supported_classes(_), do: @owned
    @impl true
    def available?(opts), do: Keyword.get(opts, :object_available?, true)
    @impl true
    def identity(_), do: {__MODULE__, :obj_v1}
    @impl true
    def detect(_image, opts), do: {:ok, regions_for(opts)}
    defp regions_for(opts) do
      case Keyword.get(opts, :classes, :all) do
        :all -> @owned
        list -> Enum.filter(list, &(&1 in @owned))
      end
      |> Enum.map(&%{label: &1, score: 0.8, box: {50, 50, 10, 10}})
    end
  end

  defp composite, do: Composite.new([FaceChild, ObjectChild])

  test "supported_classes is the union of children" do
    assert Enum.sort(Composite.supported_classes(composite())) == ["car", "dog", "face"]
  end

  test ":all runs every child and merges all regions" do
    {:ok, regions} = Composite.detect(composite(), :image, classes: :all)
    assert Enum.map(regions, & &1.label) |> Enum.sort() == ["car", "dog", "face"]
  end

  test "a class list routes only to the owning children" do
    {:ok, regions} = Composite.detect(composite(), :image, classes: ["face", "car"])
    assert Enum.map(regions, & &1.label) |> Enum.sort() == ["car", "face"]
  end

  test "unknown classes are dropped (best-effort)" do
    {:ok, regions} = Composite.detect(composite(), :image, classes: ["face", "unicorn"])
    assert Enum.map(regions, & &1.label) == ["face"]
  end

  test "all-unknown yields no regions and is available? = true (degrade, not fail)" do
    {:ok, regions} = Composite.detect(composite(), :image, classes: ["unicorn"])
    assert regions == []
    assert Composite.available?(composite(), classes: ["unicorn"]) == true
  end

  test "identity reflects only routed children, ordered by child order" do
    assert Composite.identity(composite(), classes: ["face"]) ==
             {Composite, [{FaceChild, :face_v1}]}

    assert Composite.identity(composite(), classes: ["car"]) ==
             {Composite, [{ObjectChild, :obj_v1}]}

    # URL order invariance: face:dog vs dog:face produce the same identity list
    assert Composite.identity(composite(), classes: ["face", "dog"]) ==
             Composite.identity(composite(), classes: ["dog", "face"])

    assert Composite.identity(composite(), classes: :all) ==
             {Composite, [{FaceChild, :face_v1}, {ObjectChild, :obj_v1}]}
  end

  test "available? requires every routed child to be available" do
    c = composite()
    assert Composite.available?(c, classes: ["face"], object_available?: false) == true
    assert Composite.available?(c, classes: ["car"], object_available?: false) == false
    assert Composite.available?(c, classes: :all, object_available?: false) == false
  end
end
```

Note the test calls `Composite.detect/3`, `Composite.identity/2`, `Composite.available?/2`, `Composite.supported_classes/1` taking an explicit composite value built by `Composite.new/1`. The behaviour callbacks (`detect/2`, `identity/1`, `available?/1`, `supported_classes/1`) wrap these by reading the default child list — see Step 3.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/transform/detector/composite_test.exs`
Expected: FAIL — `Composite` is undefined.

- [ ] **Step 3: Implement the Composite**

Create `lib/image_pipe/transform/detector/composite.ex`. It implements the `Detector` behaviour using a built-in default child list, and also exposes arity-`+1` helpers that take an explicit child list (used by tests and internally). Routing filters the **fixed ordered child list** by `supported_classes`.

```elixir
defmodule ImagePipe.Transform.Detector.Composite do
  @moduledoc """
  A `ImagePipe.Transform.Detector` that fans a requested class set out across an
  ordered list of child detectors and merges their regions.

  Each requested class routes to the child(ren) whose `supported_classes/1` claim
  it (`:all` routes to every child); classes no child claims are dropped
  (best-effort). Identity and availability are class-aware: they reflect only the
  children a given request routes to, so e.g. an object-only request is unaffected
  by a face-model change. The bundled default composes the face (YuNet) and object
  (RT-DETR) adapters.
  """
  @behaviour ImagePipe.Transform.Detector

  alias ImagePipe.Transform.Detector.ImageVision

  @default_children [ImageVision.Face, ImageVision.Objects]

  @type t :: %__MODULE__{children: [module()]}
  defstruct children: @default_children

  @spec new([module()]) :: t()
  def new(children) when is_list(children), do: %__MODULE__{children: children}

  @spec default() :: t()
  def default, do: %__MODULE__{children: @default_children}

  # --- Detector behaviour (uses the default child list) ---

  @impl true
  def supported_classes(_opts), do: supported_classes(default())

  @impl true
  def detect(image, opts), do: detect(default(), image, opts)

  @impl true
  def available?(opts), do: available?(default(), opts)

  @impl true
  def identity(opts), do: identity(default(), opts)

  @impl true
  def warmup(opts) do
    Enum.reduce_while(default().children, :ok, fn child, _ ->
      case ImagePipe.Transform.Detector.warmup(child, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # --- Explicit-composite helpers ---

  @spec supported_classes(t()) :: [String.t()]
  def supported_classes(%__MODULE__{children: children}) do
    children |> Enum.flat_map(& &1.supported_classes([])) |> Enum.uniq()
  end

  @spec detect(t(), term(), keyword()) :: {:ok, [map()]}
  def detect(%__MODULE__{} = composite, image, opts) do
    classes = Keyword.get(opts, :classes, :all)

    regions =
      composite
      |> routed(classes)
      |> Enum.flat_map(fn {child, child_classes} ->
        case child.detect(image, Keyword.put(opts, :classes, child_classes)) do
          {:ok, regions} -> regions
          {:error, _} -> []
        end
      end)

    {:ok, regions}
  end

  @spec available?(t(), keyword()) :: boolean()
  def available?(%__MODULE__{} = composite, opts) do
    classes = Keyword.get(opts, :classes, :all)

    composite
    |> routed(classes)
    |> Enum.all?(fn {child, _} -> child.available?(opts) end)
  end

  @spec identity(t(), keyword()) :: {module(), [term()]}
  def identity(%__MODULE__{} = composite, opts) do
    classes = Keyword.get(opts, :classes, :all)
    ids = composite |> routed(classes) |> Enum.map(fn {child, _} -> child.identity(opts) end)
    {__MODULE__, ids}
  end

  # Returns [{child_module, child_classes}] for the children that the requested
  # class set routes to, preserving the fixed child order. `:all` -> every child
  # gets `:all`. A class list -> each child gets the intersection with its
  # supported set, and children with an empty intersection are dropped.
  defp routed(%__MODULE__{children: children}, :all) do
    Enum.map(children, &{&1, :all})
  end

  defp routed(%__MODULE__{children: children}, classes) when is_list(classes) do
    requested = MapSet.new(classes)

    children
    |> Enum.map(fn child ->
      child_classes = Enum.filter(child.supported_classes([]), &MapSet.member?(requested, &1))
      {child, child_classes}
    end)
    |> Enum.reject(fn {_child, child_classes} -> child_classes == [] end)
  end
end
```

- [ ] **Step 4: Run the Composite tests to verify they pass**

Run: `mise exec -- mix test test/image_pipe/transform/detector/composite_test.exs`
Expected: PASS (all 7 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/detector/composite.ex test/image_pipe/transform/detector/composite_test.exs
git commit -m "feat(detector): add Composite router with class-aware identity/availability"
```

---

## Task 5: Make `:default` resolve to the Composite

**Files:**
- Modify: `lib/image_pipe/transform.ex:76`
- Modify: `lib/image_pipe/transform/detector/warmup.ex` (default `classes: :all`)

- [ ] **Step 1: Repoint the default detector**

In `lib/image_pipe/transform.ex:76`:

```elixir
  @default_detector ImagePipe.Transform.Detector.Composite
```

- [ ] **Step 2: Warm both models by default**

In `lib/image_pipe/transform/detector/warmup.ex`, change the default classes in `init/1` from `["face"]` to `:all` so the bundled Composite warms both children:

```elixir
      classes: Keyword.get(opts, :classes, :all),
```

Update the moduledoc example to `{ImagePipe.Transform.Detector.Warmup, detector: :default}` (no explicit `classes:` needed; `:all` warms everything).

- [ ] **Step 3: Compile + run the suites that prove the unchanged paths**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix test test/image_pipe/transform/`
Expected: PASS — and specifically these existing tests must stay green to *prove* the Composite-as-default didn't perturb the shipped paths (they inject `FakeDetector`, but `warmup_test` resolves `:default` which is now the Composite warming two unavailable children → must degrade cleanly):
- `crop_operation_test.exs` — `"face_assist blends attention with the face centroid"` (face-assist unchanged), the `{:detect, ["face"]}` crop test, and `"anchors on the area-weighted centroid of detected boxes"` (equal-weight `area` centroid unchanged).
- `detector/warmup_test.exs` — the `:default`-path warmup expectations (now warms both children; unavailable → clean no-op/degraded path, not a crash).

If any of these regress, the Composite default broke a shipped contract — fix the production code, not the test.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/transform.ex lib/image_pipe/transform/detector/warmup.ex
git commit -m "feat(detector): default detector is the Composite (face + objects)"
```

---

## Task 6: Plan `{:detect, :all}` sentinel end-to-end (types, detect_classes, key_data)

**Files:**
- Modify: `lib/image_pipe/plan/operation.ex` — **`smart_guide/1` validation gate** (the actual producer that rejects `:all`)
- Modify: `lib/image_pipe/plan/operation/resize.ex` — `guide` type (the fill path builds a `Resize`)
- Modify: `lib/image_pipe/plan/operation/crop_guided.ex` (guide type)
- Modify: `lib/image_pipe/transform/operation/crop.ex` (gravity type)
- Modify: `lib/image_pipe/plan.ex:88-99` (`detect_classes/1` `@spec`)
- Modify: `lib/image_pipe/plan/key_data.ex:198` (`guide_data`)
- Test: `test/image_pipe/plan/operation_key_data_test.exs` (the `describe "guide_data via CropGuided cache data"` block builds `%CropGuided{}` literals — mirror it for `:all`)

**Critical (caught in plan review):** `{:detect, :all}` is rejected at *operation construction* by `lib/image_pipe/plan/operation.ex`'s `smart_guide/1` (its clause is `smart_guide({:detect, classes}) when is_list(classes) and classes != []`, falling through to `{:error, :guide}`). This gate is hit by **both** `Operation.crop_guided/4` (crop path) **and** `Operation.resize/4` (fill path), so without this edit `rs:fill:100:100/g:obj` — the most common form — fails before any downstream code runs. Both `operation.ex` (the gate) and `resize.ex` (its `guide` type) must accept the sentinel.

- [ ] **Step 1: Write the failing key-data test for `:all`**

The key-data guide test lives in `test/image_pipe/plan/operation_key_data_test.exs`, in `describe "guide_data via CropGuided cache data"` (~line 261), which calls `KeyData.data(%CropGuided{…, guide: {:detect, ["face"]}})` on `%CropGuided{}` literals (the file already builds these structs, so it is sanctioned here). Add, mirroring the neighboring `{:detect, ["face"]}` case exactly (copy its `%CropGuided{}` construction and the way it extracts the `guide:` key data):

```elixir
    test "detect :all guide encodes as classes: :all" do
      data = KeyData.data(%CropGuided{width: {:px, 100}, height: {:px, 100}, guide: {:detect, :all}})
      # extract the guide key-data the same way the {:detect, ["face"]} test does:
      assert Keyword.get(guide_key_data(data), :classes) == :all
    end
```

Match the file's real `%CropGuided{}` field shape and its existing guide-extraction (the helper/inline match the neighboring test uses) — do not invent a `guide_key_data/1` if the file extracts differently.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/plan/operation_key_data_test.exs`
Expected: FAIL — `guide_data({:detect, :all})` has no clause (`FunctionClauseError`, since the existing clause is guarded `when is_list(classes)`).

- [ ] **Step 3: Add the type and the key-data clause**

In `lib/image_pipe/plan/operation.ex`, add a `smart_guide/1` clause for the sentinel **before** the existing `{:detect, classes}` clause (line 679):

```elixir
  defp smart_guide({:detect, :all} = guide), do: {:ok, guide}

  defp smart_guide({:detect, classes} = guide)
       when is_list(classes) and classes != [] do
```

In `lib/image_pipe/plan/operation/resize.ex`, extend the `guide` type (line 28):

```elixir
          | {:detect, :all}
          | {:detect, nonempty_list(String.t())}
```

In `lib/image_pipe/plan/operation/crop_guided.ex`, extend the `guide` type (line 33):

```elixir
          | {:detect, :all}
          | {:detect, nonempty_list(String.t())}
```

In `lib/image_pipe/transform/operation/crop.ex`, extend the `gravity` type (line 132):

```elixir
            | {:detect, :all}
            | {:detect, [String.t()]}
```

In `lib/image_pipe/plan/key_data.ex`, add a clause **before** the existing `is_list` clause (line 198):

```elixir
  defp guide_data({:detect, :all}), do: [type: :detect, classes: :all]

  defp guide_data({:detect, classes}) when is_list(classes),
    do: [type: :detect, classes: Enum.sort(classes)]
```

In `lib/image_pipe/plan.ex`, widen the `detect_classes/1` `@spec` (line 89). The body already returns whatever `classes` is bound to in `{:detect, classes}`, so `:all` flows through unchanged:

```elixir
  @spec detect_classes(t()) :: :all | nonempty_list(String.t()) | nil
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/plan/operation_key_data_test.exs`
Expected: PASS.

- [ ] **Step 5: Compile with warnings-as-errors**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: PASS (no missing-clause or type warnings).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/plan lib/image_pipe/transform/operation/crop.ex
git commit -m "feat(plan): add {:detect, :all} sentinel through types, detect_classes, key_data"
```

---

## Task 7: imgproxy parser — multi-class object gravity and `:all`

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex` — **both** `resize_guide/2` (lines 645-650, the fill path) **and** `tagged_gravity/2` (lines 662-667, the crop path)
- Test: `test/image_pipe/parser/imgproxy/plan_builder_test.exs` (flip the existing rejection cases to acceptance)

The grammar (`option_grammar.ex`) already parses `g:obj…` / `c:W:H:obj…` into `{:obj, classes}` with `classes == []` for bare `obj`, so only the plan-builder mapping changes.

**Critical:** `{:obj, …}` is mapped in **two** functions — `resize_guide/2` (used for `rs:fill` + `g:obj`, line 558) and `tagged_gravity/2` (used for `c:W:H:obj`, line 252). Both currently special-case `["face"]` and reject other classes. **Both must change identically** — update them via one shared helper so they can't diverge. (`canvas_placement/2` has no `{:obj,…}` clause and object gravity is not valid for extend/canvas, so leave it untouched.)

- [ ] **Step 1: Flip the existing rejection tests to acceptance**

`test/parser/imgproxy/plan_builder_test.exs` drives the planner with `plan_pipeline(keyword_attrs, opts)` over request structs and reads `resize.guide` / `crop.guide` (there is no `build/1`/`detect_guide/1`). The existing rejection tests to **replace** are named:
- `"rejects bare object gravity (all detected objects)"` (~line 844)
- `"rejects the all pseudo-class object gravity"` (~line 854)
- `"rejects multi-class object gravity"` (~line 864)
- `"rejects object gravity with trailing class tokens treated as offsets"` (~line 874)

Rewrite them in the file's real idiom (mirror a neighboring `{:obj, ["face"]}`/guide test for the exact `plan_pipeline` attrs and the resize/crop struct shapes). Fill path exercises `resize_guide/2`; crop path exercises `tagged_gravity/2` — cover both:

```elixir
  # fill path (resize_guide)
  test "g:obj with explicit classes maps to a detect guide with those classes" do
    {:ok, [%{resize: resize}]} = plan_pipeline(resizing_type: :fill, width: {:pixels, 100},
      height: {:pixels, 100}, gravity: {:obj, ["car", "dog"]})
    assert resize.guide == {:detect, ["car", "dog"]}
  end

  test "bare object gravity maps to detect :all" do
    {:ok, [%{resize: resize}]} = plan_pipeline(resizing_type: :fill, width: {:pixels, 100},
      height: {:pixels, 100}, gravity: {:obj, []})
    assert resize.guide == {:detect, :all}
  end

  test "the all pseudo-class maps to detect :all" do
    {:ok, [%{resize: resize}]} = plan_pipeline(resizing_type: :fill, width: {:pixels, 100},
      height: {:pixels, 100}, gravity: {:obj, ["all"]})
    assert resize.guide == {:detect, :all}
  end

  test "all appearing among classes collapses to detect :all" do
    {:ok, [%{resize: resize}]} = plan_pipeline(resizing_type: :fill, width: {:pixels, 100},
      height: {:pixels, 100}, gravity: {:obj, ["car", "all"]})
    assert resize.guide == {:detect, :all}
  end

  test "g:obj:face still maps to a face detect guide" do
    {:ok, [%{resize: resize}]} = plan_pipeline(resizing_type: :fill, width: {:pixels, 100},
      height: {:pixels, 100}, gravity: {:obj, ["face"]})
    assert resize.guide == {:detect, ["face"]}
  end

  # crop path (tagged_gravity)
  test "crop object gravity maps to a detect guide" do
    {:ok, [%{crop: crop}]} = plan_pipeline(crop: %CropRequest{width: {:pixels, 200},
      height: {:pixels, 200}, gravity: {:obj, ["car", "dog"]}})
    assert crop.guide == {:detect, ["car", "dog"]}
  end

  # behavior change: numeric trailing tokens are now unknown classes (dropped at
  # routing), NOT an error. This REPLACES "rejects ... trailing class tokens".
  test "object gravity with numeric tokens treats them as (unknown) classes, not an error" do
    {:ok, [%{resize: resize}]} = plan_pipeline(resizing_type: :fill, width: {:pixels, 100},
      height: {:pixels, 100}, gravity: {:obj, ["face", "5", "5"]})
    assert resize.guide == {:detect, ["face", "5", "5"]}
  end
```

Match the real `plan_pipeline/2` attribute names and the `resize`/`crop` accessor shape from the neighboring tests (the snippet's struct shapes are illustrative). **Explicit decision:** the old `"rejects … trailing class tokens treated as offsets"` test is *deleted and replaced* by the last test above — under best-effort dropping, `g:obj:face:5:5` is `{:detect, ["face", "5", "5"]}` where `"5"` is an unknown class dropped at routing (object gravity has no offset args). This is an intentional behavior change, not an oversight.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/parser/imgproxy/plan_builder_test.exs`
Expected: FAIL — current code returns `{:error, {:unsupported_gravity, …}}` for non-`["face"]` object gravity.

- [ ] **Step 3: Add a shared object-guide helper and call it from both mappers**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, add a private helper (place it near the other guide helpers, e.g. just above `crop_anchor_guide/2`):

```elixir
  # Maps imgproxy object gravity classes to a product-neutral detect guide.
  # Bare `obj` (empty classes) or `all` anywhere collapses to the :all sentinel;
  # otherwise the explicit class list is carried through. Shared by the fill
  # (resize_guide) and crop (tagged_gravity) paths so they cannot diverge.
  defp object_detect_guide(classes) do
    if classes == [] or "all" in classes do
      {:detect, :all}
    else
      {:detect, classes}
    end
  end
```

Then replace the `{:obj, …}` clauses in **`resize_guide/2`** (lines 647-650 — the `{:obj, ["face"]}` clause and the `{:obj, classes}` error clause) with a single clause:

```elixir
  defp resize_guide({:obj, classes}, _face_assist), do: {:ok, object_detect_guide(classes)}
```

And replace the `{:obj, …}` clauses in **`tagged_gravity/2`** (lines 664-667) with a single clause:

```elixir
  defp tagged_gravity({:obj, classes}, _face_assist), do: {:ok, object_detect_guide(classes)}
```

(`g:obj:face` now flows through `object_detect_guide(["face"])` → `{:detect, ["face"]}` — the dedicated `["face"]` clauses are removed because the general helper covers them.)

- [ ] **Step 4: Run the parser tests to verify they pass**

Run: `mise exec -- mix test test/parser/imgproxy/plan_builder_test.exs`
Expected: PASS.

- [ ] **Step 5: Add an order-insensitivity property test at the key-data level**

The class list is sorted in `guide_data` (`Enum.sort(classes)`), so order-insensitivity is a key-data property. Add to `test/image_pipe/plan/operation_key_data_test.exs` (self-contained, uses the file's `KeyData.data/1` + `%CropGuided{}` idiom and the project's `StreamData` import):

```elixir
  property "detect-guide class order does not change the guide key data" do
    check all classes <- uniq_list_of(member_of(["car", "dog", "cat", "person"]), min_length: 1, max_length: 4) do
      a = KeyData.data(%CropGuided{width: {:px, 100}, height: {:px, 100}, guide: {:detect, classes}})
      b = KeyData.data(%CropGuided{width: {:px, 100}, height: {:px, 100}, guide: {:detect, Enum.shuffle(classes)}})
      assert a == b
    end
  end
```

Match the file's real `StreamData`/`ExUnitProperties` import and `%CropGuided{}` field shape.

- [ ] **Step 6: Run + commit**

Run: `mise exec -- mix test test/parser/imgproxy/plan_builder_test.exs test/image_pipe/plan/operation_key_data_test.exs`
Expected: PASS.

```bash
git add lib/image_pipe/parser/imgproxy/plan_builder.ex test/parser/imgproxy/plan_builder_test.exs test/image_pipe/plan/operation_key_data_test.exs
git commit -m "feat(imgproxy): parse multi-class object gravity and all/bare obj -> detect"
```

---

## Task 8: Class-aware cache identity and strict gate

**Files:**
- Modify: `lib/image_pipe/request/runner.ex:238-247`
- Modify: `lib/image_pipe/plug.ex:143-151`
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs` (observe the cache key via `CacheProbe`)

The class-aware *identity routing* is already unit-proven in Task 4 (`Composite.identity/2`). What Task 8 adds is the *wiring*: the runner threads the plan's detect classes into `detector_identity`, and the plug threads them into the availability gate. The runner wiring's observable effect is the **cache key**, which the wire test's `CacheProbe` reports via `{:cache_lookup, key}` — so verify at the wire level (no fictional `key_for`; `Cache.Key.build` takes `detector_identity` literally and never resolves a detector). The plug wiring is verified by Task 10's gate triad.

- [ ] **Step 1: Write the failing class-aware key tests (wire-level, via CacheProbe)**

`detector:` resolves a **module atom**. Define one named detector module that delegates to `Composite.new(...)` with fake children whose identity *version* is read from `opts` — so a single module covers the version-bump independence checks. Put these in the wire test file (alongside its existing `UnavailableDetector`/`CacheProbe`):

```elixir
  defmodule FaceVerFake do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_), do: ["face"]
    @impl true
    def available?(_), do: true
    @impl true
    def identity(opts), do: {__MODULE__, Keyword.get(opts, :face_ver, :v1)}
    @impl true
    def detect(_, _), do: {:ok, []}
  end

  defmodule ObjectVerFake do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_), do: ["car", "dog"]
    @impl true
    def available?(_), do: true
    @impl true
    def identity(opts), do: {__MODULE__, Keyword.get(opts, :object_ver, :v1)}
    @impl true
    def detect(_, _), do: {:ok, []}
  end

  defmodule VerComposite do
    @behaviour ImagePipe.Transform.Detector
    alias ImagePipe.Transform.Detector.Composite
    defp c, do: Composite.new([FaceVerFake, ObjectVerFake])
    @impl true
    def supported_classes(_o), do: Composite.supported_classes(c())
    @impl true
    def detect(i, o), do: Composite.detect(c(), i, o)
    @impl true
    def available?(o), do: Composite.available?(c(), o)
    @impl true
    def identity(o), do: Composite.identity(c(), o)
  end

  # Capture the cache key the plug looked up for one request. Uses the file's
  # existing CacheProbe (it sends {:cache_lookup, key}) and call_imgproxy/2.
  defp lookup_key(path, opts) do
    call_imgproxy(path, opts)
    assert_received {:cache_lookup, key}
    key
  end

  defp ver_opts(extra) do
    # Merge into the file's CacheProbe-backed opts (see the existing cache tests),
    # adding the detector and the version knobs that flow through to identity/1.
    Keyword.merge(probe_opts(), [detector: VerComposite] ++ extra)
  end

  test "object-only request key is independent of the face model identity" do
    assert lookup_key("rs:fill:50:50/g:obj:car/plain/images/beach.jpg", ver_opts(face_ver: :v1)) ==
             lookup_key("rs:fill:50:50/g:obj:car/plain/images/beach.jpg", ver_opts(face_ver: :v2))
  end

  test "face-only request key is independent of the object model identity" do
    assert lookup_key("rs:fill:50:50/g:obj:face/plain/images/beach.jpg", ver_opts(object_ver: :v1)) ==
             lookup_key("rs:fill:50:50/g:obj:face/plain/images/beach.jpg", ver_opts(object_ver: :v2))
  end

  test "mixed request key changes when either model identity changes" do
    base = lookup_key("rs:fill:50:50/g:obj:face:car/plain/images/beach.jpg", ver_opts(face_ver: :v1, object_ver: :v1))
    diff_face = lookup_key("rs:fill:50:50/g:obj:face:car/plain/images/beach.jpg", ver_opts(face_ver: :v2, object_ver: :v1))
    diff_obj = lookup_key("rs:fill:50:50/g:obj:face:car/plain/images/beach.jpg", ver_opts(face_ver: :v1, object_ver: :v2))
    assert base != diff_face
    assert base != diff_obj
  end
```

Bind `probe_opts/0` to the file's real CacheProbe-backed opts (mirror the existing `"equivalent imgproxy option order shares filesystem cache"` / `cached_opts/0` test, or the `cache: {CacheProbe, []}` setup the safety tests use). The `face_ver`/`object_ver` reach `identity/1` because `put_detector_identity` (Step 3) passes the request `opts` (with `:classes` added) to `Transform.detector_identity/2`.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: FAIL — `put_detector_identity` currently calls `detector_identity(detector, opts)` with no `:classes`, so `Composite.identity` defaults to `:all` and folds **both** children into every key. The object-only key then changes with `face_ver`, breaking the independence assertion.

- [ ] **Step 3: Thread classes into the cache-key identity**

In `lib/image_pipe/request/runner.ex`, update `put_detector_identity/2` (lines 238-247) to pass the plan's detect classes (defaulting to `["face"]` for the face-assist-only case, which routes to the Face child):

```elixir
  defp put_detector_identity(opts, plan) do
    if Plan.detect_classes(plan) != nil or Plan.face_assist?(plan) do
      classes = Plan.detect_classes(plan) || ["face"]
      opts_with_classes = Keyword.put(opts, :classes, classes)

      case Transform.detector_identity(Keyword.get(opts, :detector, :default), opts_with_classes) do
        nil -> opts
        identity -> Keyword.put(opts, :detector_identity, identity)
      end
    else
      opts
    end
  end
```

`Transform.detector_identity/2` passes `opts` straight to `module.identity/1`, so the Composite reads `opts[:classes]` — no change needed in `transform.ex`.

- [ ] **Step 4: Thread classes into the strict gate**

In `lib/image_pipe/plug.ex`, update `validate_detector_capability/2` (lines 143-151):

```elixir
  defp validate_detector_capability(%Plan{} = plan, opts) do
    classes = Plan.detect_classes(plan)

    if Keyword.get(opts, :detector_required, false) and classes != nil do
      opts_with_classes = Keyword.put(opts, :classes, classes)

      if Transform.detector_available?(Keyword.get(opts, :detector, :default), opts_with_classes),
        do: :ok,
        else: {:error, {:detector, :unavailable}}
    else
      :ok
    end
  end
```

`Transform.detector_available?/2` passes `opts` to `module.available?/1`, so the Composite evaluates availability for the routed class set.

- [ ] **Step 5: Run the wire cache-key tests to verify they pass**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS.

- [ ] **Step 6: Compile + commit**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: PASS.

```bash
git add lib/image_pipe/request/runner.ex lib/image_pipe/plug.ex test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "feat: class-aware detector identity and strict gate"
```

---

## Task 9: Per-model telemetry spans from the Composite

The aggregate `[:transform, :detect]` span in `crop.ex` is unchanged except for threading `:telemetry_opts` into the detector opts. The Composite emits a nested `[:transform, :detect, :model]` span per child that runs.

**Files:**
- Modify: `lib/image_pipe/transform/operation/crop.ex` (`run_detect` threads `:telemetry_opts`)
- Modify: `lib/image_pipe/transform/detector/composite.ex` (emit per-model spans)
- Test: `test/image_pipe/transform/detector/composite_test.exs` (telemetry assertions)

- [ ] **Step 1: Write the failing per-model telemetry test**

Add to `composite_test.exs` (it already has fake children with `identity/1`):

```elixir
  test "emits a per-model span per routed child with detector, model identity, and classes" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [[:image_pipe, :transform, :detect, :model, :stop]])

    on_exit(fn -> :telemetry.detach(ref) end)

    {:ok, _} =
      Composite.detect(composite(), :image,
        classes: ["face", "car"],
        telemetry_opts: [telemetry_prefix: [:image_pipe]]
      )

    assert_received {[:image_pipe, :transform, :detect, :model, :stop], ^ref, _measurements,
                     %{detector: FaceChild, model: {FaceChild, :face_v1}, classes: ["face"], regions: 1}}

    assert_received {[:image_pipe, :transform, :detect, :model, :stop], ^ref, _measurements,
                     %{detector: ObjectChild, model: {ObjectChild, :obj_v1}, classes: ["car"], regions: 1}}
  end
```

The event prefix is `[:image_pipe]` (the default `Telemetry.span/4` prefix) and the opts key is `:telemetry_prefix` (NOT `:prefix`) — `Telemetry.span/4` reads `Keyword.get(telemetry_opts, :telemetry_prefix, [:image_pipe])`. Confirm against `crop_operation_test.exs`'s existing `[:image_pipe, :transform, :detect, :stop]` attachment.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec -- mix test test/image_pipe/transform/detector/composite_test.exs -k "per-model span"`
Expected: FAIL — no such event emitted.

- [ ] **Step 3: Emit per-model spans in the Composite**

In `lib/image_pipe/transform/detector/composite.ex`, alias the telemetry helper (`alias ImagePipe.Telemetry`) and wrap each child invocation in a span when `telemetry_opts` is present. Replace the `detect/3` fan-out:

```elixir
  def detect(%__MODULE__{} = composite, image, opts) do
    classes = Keyword.get(opts, :classes, :all)
    telemetry_opts = Keyword.get(opts, :telemetry_opts)

    regions =
      composite
      |> routed(classes)
      |> Enum.flat_map(fn {child, child_classes} ->
        run_child(child, child_classes, image, opts, telemetry_opts)
      end)

    {:ok, regions}
  end

  defp run_child(child, child_classes, image, opts, nil) do
    detect_child(child, child_classes, image, opts)
  end

  defp run_child(child, child_classes, image, opts, telemetry_opts) do
    start_meta = %{detector: child, model: child.identity(opts), classes: child_classes}

    Telemetry.span(telemetry_opts, [:transform, :detect, :model], start_meta, fn ->
      regions = detect_child(child, child_classes, image, opts)
      {regions, %{regions: length(regions)}}
    end)
  end

  defp detect_child(child, child_classes, image, opts) do
    case child.detect(image, Keyword.put(opts, :classes, child_classes)) do
      {:ok, regions} -> regions
      {:error, _} -> []
    end
  end
```

Confirm `ImagePipe.Telemetry.span/4`'s arity/return contract against `crop.ex`'s usage and adjust the call to match exactly (the fn must return `{value, stop_metadata}`).

- [ ] **Step 4: Thread `:telemetry_opts` from `run_detect`**

In `lib/image_pipe/transform/operation/crop.ex`, update `run_detect/5` (line 346) to pass `telemetry_opts` into the detector opts so the Composite can emit nested spans:

```elixir
  defp run_detect(module, opts, image, classes, telemetry_opts) do
    Telemetry.span(telemetry_opts, [:transform, :detect], %{classes: classes}, fn ->
      detect_opts = opts |> Keyword.put(:classes, classes) |> Keyword.put(:telemetry_opts, telemetry_opts)
      result = validate_detect_result(module.detect(image, detect_opts))
      {result, %{regions: region_count(result), result: detect_reason(result)}}
    end)
  end
```

- [ ] **Step 5: Run the telemetry test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/transform/detector/composite_test.exs`
Expected: PASS.

- [ ] **Step 6: Compile + commit**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: PASS.

```bash
git add lib/image_pipe/transform/detector/composite.ex lib/image_pipe/transform/operation/crop.ex test/image_pipe/transform/detector/composite_test.exs
git commit -m "feat(telemetry): per-model [:transform, :detect, :model] spans from Composite"
```

---

## Task 10: Wire-level pixel + gate-triad tests (FakeDetector-injected)

These assert the user-visible contract with a deterministic injected detector — no real model. They are the most important behavioral tests in the slice.

**Files:**
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Add a corner-box FakeDetector to the wire test support**

In `test/image_pipe/imgproxy_wire_conformance_test.exs` (or its support module), define a fake that places a single region in a known corner so the resulting crop is unambiguous:

```elixir
  defmodule CornerObjectDetector do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_), do: ["car", "dog", "face", "person"]
    @impl true
    def available?(opts), do: Keyword.get(opts, :available?, true)
    @impl true
    def identity(_), do: {__MODULE__, :v1}
    @impl true
    def detect(_image, opts) do
      # A small box near the top-left so a fill-crop biases up-left, distinct
      # from center and from attention saliency.
      classes = Keyword.get(opts, :classes, :all)
      label = if classes == :all, do: "car", else: List.first(List.wrap(classes))
      {:ok, [%{label: label, score: 0.95, box: {2, 2, 20, 20}}]}
    end
  end
```

- [ ] **Step 2: Write the failing pixel-divergence test for a non-face class**

```elixir
  test "g:obj:car crop biases toward the detected object, differing from center and attention" do
    opts = Keyword.merge(@default_opts, detector: CornerObjectDetector)

    obj = call_imgproxy("rs:fill:50:50/g:obj:car/plain/images/beach.jpg", opts)
    centered = call_imgproxy("rs:fill:50:50/g:ce/plain/images/beach.jpg", opts)
    attention = call_imgproxy("rs:fill:50:50/g:sm/plain/images/beach.jpg", opts)

    assert obj.status == 200
    assert dimensions(obj) == {50, 50}
    refute obj.resp_body == centered.resp_body
    refute obj.resp_body == attention.resp_body
  end

  test "no-geometry g:obj:car still detects without a resize/crop" do
    opts = Keyword.merge(@default_opts, detector: CornerObjectDetector)
    resp = call_imgproxy("g:obj:car/plain/images/beach.jpg", opts)
    assert resp.status == 200
  end
```

Use the file's real helpers: `call_imgproxy(path, opts)` (returns a `conn`), `dimensions(conn)` (decodes), the hardcoded `plain/images/beach.jpg` source, and `@default_opts` (merge to override `detector:`). Mirror the existing `g:sm` decode-and-compare pixel test for exact conventions.

- [ ] **Step 3: Run to verify failure, then implement**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs -k "g:obj:car"`
Expected: initially FAIL only if something is wrong — by this task the production code already supports `obj:car`, so these tests should **pass once written** (they validate Tasks 4–8 end-to-end). If they fail, debug the wiring (most likely the `detector:` injection or the crop divergence). Treat a genuine failure here as a real bug to fix in the production code, not the test.

- [ ] **Step 4: Write the gate-triad test**

```elixir
  test "detector_required gate: available->200, unavailable->422 pre-fetch, unknown->degrade" do
    opts = Keyword.merge(@default_opts, detector: PartialDetector, detector_required: true)

    # face child available -> routes and succeeds
    assert call_imgproxy("rs:fill:50:50/g:obj:face/plain/images/beach.jpg", opts).status == 200
    # unknown class routes to no child -> available? vacuously true -> degrades
    assert call_imgproxy("rs:fill:50:50/g:obj:unicorn/plain/images/beach.jpg", opts).status == 200

    # object child unavailable -> 422 BEFORE any source fetch or cache access.
    # Reuse the exact OriginShouldNotFetch source + CacheProbe cache from the
    # existing "detector_required + unavailable detector rejects before source AND
    # cache access" test (~line 541), then assert status + refute the side effects.
    gate_opts = Keyword.merge(opts, source: <OriginShouldNotFetch from the ~line-541 test>, cache: {CacheProbe, []})
    conn = call_imgproxy("rs:fill:50:50/g:obj:car/plain/images/beach.jpg", gate_opts)
    assert conn.status == 422
    refute_received :origin_fetch
    refute_received {:cache_lookup, _key}
  end
```

`PartialDetector` is a named module delegating to `Composite.new([FaceFake, UnavailableObjectFake])` (same delegation shape as `VerComposite` in Task 8). `FaceFake` is available, owns `["face"]`, and its `detect/2` returns a region so `g:obj:face` → 200. `UnavailableObjectFake` owns `["car"]` with `available?/1 -> false`, so `g:obj:car` routes to it → `available?` false → 422 pre-fetch; `g:obj:unicorn` routes to no child → `available?` vacuously true → degrades to 200. The 422 leg must copy the line-541 test's `OriginShouldNotFetch` + `CacheProbe` opts and its `refute_received :origin_fetch` / `refute_received {:cache_lookup, _}` assertions verbatim.

- [ ] **Step 5: Run the wire tests**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(wire): obj:car pixel divergence, no-geometry, and detector_required gate triad"
```

---

## Task 11: Architecture boundary — parser/plan must not name detectors

**Files:**
- Modify: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Extend the detector-reference scan to parser + plan**

The detector scan (test at line 329) reads the `@detector_forbidden_globs` **module attribute** (line 13), currently covering plug/request/source/response/cache. Add `lib/image_pipe/parser/**/*.ex` and `lib/image_pipe/plan/**/*.ex` to **that attribute** (NOT to `@parser_forbidden_globs` at line 24, which drives a different parser-struct scan — keep the two glob sets separate). The existing `concrete_detector_references/1` AST scan then forbids parser/plan code from naming `ImagePipe.Transform.Detector.*`. Do NOT add a COCO-label denylist — only the detector-module scan (a label denylist would itself leak vocabulary into the test).

First confirm no plan/parser file already names a detector module:

Run: `grep -rn "Transform.Detector" lib/image_pipe/parser lib/image_pipe/plan`
Expected: no matches (parser emits `{:detect, …}` atoms; plan/key_data name no detector). If a match exists, that's a real boundary violation to fix before this test will pass.

- [ ] **Step 2: Run the architecture test**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS — the parser maps to product-neutral `{:detect, …}` guides and never names a detector module, so no violations.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/architecture_boundary_test.exs
git commit -m "test(arch): forbid parser/plan code from naming concrete detectors"
```

---

## Task 12: Demo controls + URL state

**Files:**
- Modify: `demo/` Svelte app (controls + URL state for object gravity)

- [ ] **Step 1: Locate the gravity controls in the demo**

Run: `mise exec -- grep -rln "g:obj\|smart_crop\|gravity" demo/src`
Expected: the control component(s) and URL-state module that already handle `g:sm` / `g:obj:face`.

- [ ] **Step 2: Add object-class gravity controls**

Add a control that lets the user pick object gravity: a mode (`none` / `sm` / `obj`), and when `obj`, a multi-select of the COCO-80 classes (underscore spelling) plus an explicit `all` option and a bare-`obj` (empty) option. Wire the selection into the URL builder so it emits `g:obj`, `g:obj:all`, or `g:obj:%c1:…:%cN`. Keep `detector: :default` wiring.

Follow the existing control/URL-state pattern exactly (mirror how `g:obj:face` is built today). The COCO-80 underscore list is the same one hardcoded in `ImageVision.Objects` — keep them consistent (a short comment in the demo pointing at the adapter is enough; do not import server code into the demo).

- [ ] **Step 3: Run the demo verify suite**

Run: `mise run precommit:demo`
Expected: PASS (Elixir gate + `mix demo.verify`).

- [ ] **Step 4: Commit**

```bash
git add demo
git commit -m "feat(demo): object-class gravity controls and URL state"
```

---

## Task 13: Documentation

**Files:**
- Modify: `docs/content-aware-gravity.md`, `docs/imgproxy_support_matrix.md`, `docs/telemetry.md`

- [ ] **Step 1: `content-aware-gravity.md`**

Add a "General object gravity" section: `g:obj:%classN`, `g:obj`/`g:obj:all` include faces (the union of detectors), best-effort drop of unknown classes (degrades, never errors), class-aware cache identity, the underscore class spelling, and that the equal-weight default biases toward larger objects (face-centric crops use `g:obj:face` or, later, `objw`). Note RT-DETR cold-start/model size (~175 MB) and `mix image_vision.download_models --detect`. Update the existing "imgproxy compatibility & divergences" paragraph (it currently says general object classes/`objw` are out of scope) to say multi-class + `all` are now supported and only `objw`/`objects_position` remain out (Slice 2 / out of scope).

- [ ] **Step 2: `imgproxy_support_matrix.md`**

Update the object-gravity row: multi-class and `all` supported; `objw`/`objects_position` still out. Keep the YuNet-vs-imgproxy-YOLO divergence note and add the RT-DETR/COCO-80 object model.

- [ ] **Step 3: `telemetry.md`**

Document the per-model `[:transform, :detect, :model]` span (`detector` module name + `model` = the child's `identity/1`; the union of per-model `classes` is the effective set, so a dropped class is a requested class missing from every per-model span) and add the one-line "keep custom `identity/1` free of secrets" note for custom-detector authors.

- [ ] **Step 4: Commit**

```bash
git add docs/content-aware-gravity.md docs/imgproxy_support_matrix.md docs/telemetry.md
git commit -m "docs: general object gravity, support matrix, per-model telemetry"
```

---

## Task 14: Full gate + final verification

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
Expected: PASS — `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all green.

- [ ] **Step 2: Run the demo gate**

Run: `mise run precommit:demo`
Expected: PASS.

- [ ] **Step 3: Run the ML-tagged lane once to verify the live adapters**

Run: `IMAGE_VISION=1 mise exec -- mix test --only image_vision`
Expected: PASS (Objects drift/smoke/vocabulary; any existing face-model tagged tests). If the model download is slow on a cold machine, this is the expected one-time cost.

- [ ] **Step 4: Final review against the spec**

Re-read `docs/superpowers/specs/2026-05-31-object-gravity-slice1-design.md` and confirm each section maps to a landed task. Note any gap for follow-up.

- [ ] **Step 5: No commit needed** if everything was committed per-task. Otherwise commit any docs/cleanup.

---

## Spec coverage map

- Detector `supported_classes/1` → Task 1
- Split Face / new Objects adapter → Tasks 2, 3
- Composite (routing, merge, class-aware identity/availability) → Task 4
- `:default` = Composite, warmup both → Task 5
- Plan `{:detect, :all}` (types, `detect_classes`, `key_data`) → Task 6
- Parser multi-class / `all` / bare-`obj`, vocabulary-free → Task 7
- Class-aware cache identity + strict gate threading → Task 8
- Per-model telemetry spans → Task 9
- Wire pixel (non-face) + no-geometry + gate triad → Task 10
- Architecture boundary (parser/plan ⊬ detectors) → Task 11
- Demo controls → Task 12
- Docs (gravity, support matrix, telemetry) → Task 13
- Real-model tagged smoke + drift + full gate → Tasks 3, 14
- Equal-weight `area` centroid unchanged (Slice 2 = `objw`) → no task (explicitly untouched; covered by existing focal tests staying green in Tasks 5, 14)
