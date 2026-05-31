# Object-oriented gravity — Slice 1: general object gravity (equal-weight)

**Status:** approved design, pre-implementation (revised after parallel review)
**Date:** 2026-05-31
**Builds on:** the smart-gravity / ML-detection seam landed in #130 (`g:sm`,
`g:obj:face`, face-assist, the `ImagePipe.Transform.Detector` behaviour, the
bundled `ImageVision` YuNet adapter, `focal_from_regions`, detector identity in
the cache key, the `detector_required` gate, `[:transform, :detect]` telemetry,
`Detector.Warmup`).

> **Review revisions (2026-05-31).** A four-reviewer parallel cycle (boundary,
> cache/runtime correctness, `image_vision` integration reality, test
> strategy/scope) ran against this spec. Accepted changes folded in below: the
> per-model span emits the child **module name** + its `identity/1` (version-bearing
> `{repo, filename, min_score}` for the bundled adapters), with a one-line doc
> contract that custom `identity/1` stays secret-free — the model-artifact name is
> harmless public metadata, and a reviewer's stricter "never emit the identity"
> reading was relaxed as far-fetched (no guard code); made the class-threading
> wiring explicit at *both* the plug gate and the
> runner key-build; enumerated the `:all` producer edits (`detect_classes/1`,
> `KeyData.guide_data/1`, the `CropGuided`/`crop` typespecs); corrected the Objects
> adapter to use `:filename` / no `:nms_iou` / `available? =
> ensure_loaded?(Image.Detection)` and to derive `supported_classes` from the
> public `Image.Detection.classes/0`; resolved COCO label spelling
> (underscore↔space normalization); strengthened the test plan (FakeDetector-driven
> wire pixel test for a non-face class + a no-geometry variant, the gate triad,
> merge-via-fake-children, continuity-as-invariant); and added ML-nondeterminism
> and model-size risks. The integration reviewer **confirmed** the central
> `Image.Detection.detect/2` API assumption against the installed `image_vision
> 0.4.0` (same `region` shape, COCO-80, options `min_score`/`repo`/`filename`).

## Goal

Extend ImagePipe's content-aware gravity from the single-class `face` subset to
imgproxy's general object gravity:

- `gravity:obj:%class1:…:%classN` — multi-class object gravity.
- `gravity:obj` with classes omitted — use **all** detected objects.
- The `all` pseudo-class.
- The `c:W:H:obj…` crop forms, same class grammar.

**Out of scope for this slice (deferred to Slice 2):** `gravity:objw` per-class
weights and the weighted-centroid formula. They are purely additive on top of
the Composite this slice builds, so deferring them requires no rework. Slice 1
keeps the existing equal-weight area centroid (`focal_from_regions`) unchanged.

Existing behavior — `g:obj:face`, face-assisted `g:sm`
(`smart_crop_face_detection`), plain `g:sm`, and every non-detection path — is
preserved unchanged. `g:obj:face`'s cache keys remain byte-identical (see
§ Cache identity).

## Why these choices (decision record)

The design was brainstormed decision-by-decision. The settled answers:

1. **Model strategy — composite/routing detector.** COCO-80 (RT-DETR) has
   `person` but **no `face`**; the shipped `obj:face` is backed by YuNet. A mixed
   request (`obj:face:dog`) genuinely needs both models. A product-neutral
   Composite routes each requested class to the detector that owns it, fans out
   to only the needed models, and merges regions. This keeps `obj:face` on YuNet
   exactly as today, and a COCO-only alternative (remap `face`→`person`/drop) was
   rejected because it would silently change already-shipped `obj:face` and
   face-assist semantics.
2. **`all` / bare `obj` includes faces.** To the end user, a face is one of the
   objects the system can detect; excluding it from "all" would be a surprising
   special case. `all` = the union of every configured child detector's classes,
   so `obj` / `obj:all` runs both models. This also makes Slice 2's
   `objw:all:N:face:M` a clean override model (face ∈ all). Honest cost: both
   models run for `all` requests, and on a person photo RT-DETR `person` and
   YuNet `face` can both fire — Slice 2 weights are what favor the face; Slice 1's
   equal-weight default biases toward the larger `person` box, which is the
   faithful imgproxy equal-weight default.
3. **Weighted-centroid formula — deferred to Slice 2.** The formula choice only
   bites once weights exist. Slice 1 keeps the existing `area` centroid. Slice 2
   will settle `weight·area` vs `weight·√area` vs `weight`-only via dev-loop
   experimentation behind a **dev/test-only** toggle removed before merge (never a
   public/plug option).
4. **Cache identity is class-aware.** Per-request detector identity reflects only
   the models that actually run for that request's class set (see § Cache
   identity).
5. **Unknown classes are best-effort dropped, never an error.** imgproxy's docs do
   not specify unknown-class behavior (its class vocabulary is host-configured via
   a classes file), so there is no compatibility contract to honor. A class no
   configured child claims is simply dropped during routing; if nothing usable
   remains the request behaves like "no detection" (graceful attention fallback,
   or 422 under `detector_required` only when a *real, supported* class has no
   available detector). Dropped classes are observable via telemetry
   (`effective_classes`). No new config knob.
6. **Telemetry — aggregate span + per-model nested spans.** Keeps honest total
   timing and restores per-model cold-start visibility that today's single face
   span has. The per-model span identifies the child by **module name** plus its
   **`identity/1`** (for the bundled adapters that is `{repo, filename, min_score}`
   — version-bearing, so the span shows which model version ran). The model-artifact
   name is harmless public metadata, so this is fine to emit; custom-detector
   authors are told (one doc line) to keep `identity/1` free of secrets, rather than
   the library adding guard code for that far-fetched case (see § Telemetry).
7. **Config — minimal.** Keep `detector` / `detector_required`. `:default` becomes
   the Composite with baked-in default models and per-child default `min_score`.
   Hosts tune via the existing custom-detector extension point. Model
   `repo`/`filename`/`min_score` are *not* new plug options.
8. **Scope — two slices.** This is Slice 1 (general object gravity). `objw` is
   Slice 2.

## Architecture

### Detector behaviour: add `supported_classes/1`

`ImagePipe.Transform.Detector` gains one callback:

```elixir
@callback supported_classes(opts :: keyword()) :: [String.t()]
```

- Returns the class set the detector owns. **Static and cheap** — it must not
  load a model. A detector may return its full vocabulary even when
  `available?/1` is `false` (deps missing), because the vocabulary is metadata,
  not a runtime capability.
- The Composite uses it to route a requested class set to children and to
  evaluate per-request availability and identity.
- `detect/2`'s `classes` opt is now `:all | [String.t()]`. `:all` means "every
  region this detector can produce" (no class filter).

This is a real `@impl` behaviour callback, not a duck-typing probe — consistent
with the repo's "call the callback, let missing callbacks raise" stance. No other
new callback is needed — the per-model telemetry span reuses the existing
`identity/1` (see § Telemetry).

### Adapters: split the bundled `ImageVision` into Face + Objects

The current single `ImagePipe.Transform.Detector.ImageVision` (YuNet face) is
split into two product-neutral adapter modules under the same namespace.

> Integration facts confirmed against the installed `image_vision 0.4.0`
> (`deps/image_vision/lib/{face_detection,detection}.ex`): both `detect`
> functions return a bare list of `%{label, score, box: {x, y, width, height}}`
> (absolute top-left pixels, sorted by score desc) — **identical** to our
> `Detector.region` shape, with no tuple-order or normalized-vs-abs mismatch.
> Key asymmetries between the two image_vision APIs to respect:
> - Face uses option `:model_file`; **Objects uses `:filename`**.
> - Objects has **no `:nms_iou`** (RT-DETR is NMS-free); Face does.
> - Objects results carry a real `label`; the Face adapter sets `"face"` itself.

- **`ImagePipe.Transform.Detector.ImageVision.Face`**
  - Wraps `Image.FaceDetection.detect/1` (YuNet), as today.
  - `supported_classes(_) → ["face"]`.
  - `detect/2`: returns face regions for `classes == ["face"]` or `:all`; an empty
    routed subset returns `{:ok, []}`.
  - `available?/1`: `Code.ensure_loaded?(Image.FaceDetection)`, as today.
  - `identity/1`: `{__MODULE__, {repo, model_file, min_score}}`.
  - `warmup/1`: blank-image detect to trigger model load, as today.
  - Keeps the existing narrow `rescue` boundary around the optional-dep call.

- **`ImagePipe.Transform.Detector.ImageVision.Objects`** (new)
  - Wraps `Image.Detection.detect/2` (RT-DETR, COCO-80).
  - `supported_classes(_)` **derives from the public `Image.Detection.classes/0`**
    (the 80 COCO labels image_vision exposes) rather than hardcoding a second,
    drift-prone copy. Cheap, static, no model load.
  - `detect/2`: runs detection (option `min_score`), filters results to the routed
    classes (or returns all for `:all`).
  - `available?/1`: `Code.ensure_loaded?(Image.Detection)` (mirrors Face).
  - `identity/1`: `{__MODULE__, {repo, filename, min_score}}` — note `:filename`,
    **not** `:model_file`.
  - `warmup/1`: blank-image detect to trigger model load.
  - Keeps the same narrow `rescue` boundary as the Face adapter (optional-dep /
    `Ortex.run` / model-fetch can raise).
  - **Defaults (from image_vision 0.4.0):** `repo: "onnx-community/rtdetr_r50vd"`,
    `filename: "onnx/model.onnx"` (~175 MB; a ~45 MB quantized variant exists via
    `filename: "onnx/model_quantized.onnx"`), `min_score: 0.5`.

**Class spelling — underscore↔space normalization.** The model's COCO labels use
**spaces** for multi-word classes (`"traffic light"`, `"fire hydrant"`, `"stop
sign"`, `"sports ball"`, `"baseball bat"`, `"cell phone"`, `"dining table"`, `"hot
dog"`, `"potted plant"`, `"teddy bear"`, `"hair drier"`, `"wine glass"` — 12 of
80). Spaces are URL-hostile and imgproxy class files conventionally use
underscores. So the Objects adapter normalizes underscores↔spaces when matching
requested classes against `supported_classes` and when filtering results, so a URL
class like `obj:traffic_light` routes correctly. `supported_classes/1` may report
the underscore form (the URL-facing spelling); the single-word classes (`person`,
`car`, `dog`, …) are unaffected. This normalization is a property of the Objects
adapter (vocabulary owner), not the parser.

### `ImagePipe.Transform.Detector.Composite` (new)

A product-neutral router holding an **ordered list of child detectors**.

- **Construction:** `:default` resolves to `Composite[Face, Objects]` (in that
  order). Children carry their own default opts (models, `min_score`).
- **`detect(image, opts)`** where `opts[:classes]` is `:all | [String.t()]`:
  - `:all` → run **every** child with `classes: :all`; merge all regions.
  - list → for each child, compute `routed = requested ∩ child.supported_classes`
    (under the adapter's spelling normalization); run only children with a
    non-empty `routed` (passing `classes: routed`); merge regions. Classes claimed
    by no child are **dropped** (best-effort).
  - Merge is region-list concatenation (order-independent for the equal-weight
    area centroid). Each merged region **retains its `label`** (so Slice 2 can
    weight per class with no merge change). De-duplication of overlapping
    `person`/`face` is **not** performed — both contribute by area; Slice 2 weights
    arbitrate.
- **`supported_classes(opts)`** → union of children's `supported_classes`.
- **`available?(opts)`** → evaluated for the request's class set
  (`opts[:classes]`, threaded in by the gate): the children that the class set
  routes to must be available. `:all` routes to all children → all must be
  available. An all-unknown set routes to **no** child, so there is no
  required-but-unavailable child → `available?` returns **true** (the request will
  degrade to attention at execution, not 422). Used by the strict gate.
- **`identity(opts)`** → the identities of the children the request's class set
  routes to, built by **filtering the fixed ordered child list** (never by
  iterating the requested class set), so identity is invariant to URL class order.
  Class-aware (see § Cache identity).

### Plan representation

`ImagePipe.Plan.Operation.CropGuided`'s `guide` type gains the `:all` sentinel
alongside the existing class-list form:

```elixir
{:detect, :all} | {:detect, nonempty_list(String.t())}
```

- `:all` stays a **sentinel** resolved inside the Composite at detection time. It
  is never expanded to a concrete class list at parse/plan time — doing so would
  force the parser/planner to know the detector's vocabulary, violating the
  namespace boundary (parser owns syntax, detector owns vocabulary).

**Required producer edits for the `:all` shape** (each is a real code path a wire
`obj`/`obj:all` request hits — missing any one crashes or silently misbehaves):

1. `ImagePipe.Plan.Operation.CropGuided` — `guide` type gains `{:detect, :all}`.
2. `lib/image_pipe/transform/operation/crop.ex` — the operation `gravity`
   typespec and the `execute/2` detect arm accept `{:detect, :all}` (the existing
   `gravity: {:detect, classes}` head matches with `classes = :all`; confirm
   `run_detect`/telemetry carry `classes` as `:all | list`).
3. `ImagePipe.Plan.detect_classes/1` — `@spec` and body widen to
   `:all | nonempty_list(String.t()) | nil`.
4. `lib/image_pipe/plan/key_data.ex` — add a `guide_data({:detect, :all})` clause
   returning `[type: :detect, classes: :all]` (today's clause is guarded
   `when is_list(classes)` and would `FunctionClauseError` on `:all`). The list
   clause keeps `classes: Enum.sort(classes)`.

### Parser (imgproxy) — stays vocabulary-free

In `lib/image_pipe/parser/imgproxy/`:

- `option_grammar.ex` already parses `g:obj:…` and `c:W:H:obj:…` into
  `{:obj, classes}` with no parse-time validation, preserving the literal class
  list including `[]` (bare `g:obj`) and a literal `"all"` token. Confirm both
  `g:` and `c:W:H:` forms; no grammar change expected beyond confirmation.
- `plan_builder.ex` — replace the hard `["face"]`-only gate in `tagged_gravity/2`:
  - `{:obj, classes}` where `classes == []` or `"all" ∈ classes` → `{:detect, :all}`
  - `{:obj, classes}` (non-empty, no `all`) → `{:detect, classes}`
  - (the previous `{:obj, ["face"]}` special case and the
    `{:unsupported_gravity, …}` rejection for other classes are removed)
- The parser/planner must not enumerate COCO classes or import any detector
  module — it only restructures syntax into a product-neutral `{:detect, …}`
  guide. `all`-normalization is an imgproxy dialect quirk and stays isolated here.
- `objw` is **not** parsed this slice; it remains an unknown option (errors as
  today). Slice 2 adds it.

### Transform / crop execution

In `lib/image_pipe/transform/operation/crop.ex`:

- `detect_crop` handles `{:detect, :all}` and `{:detect, [classes]}` uniformly,
  threading `classes` (`:all` or list) into the detector opts.
- `focal_from_regions` is **unchanged** — equal-weight area centroid, label-
  agnostic (reads only `box`, filters in-bounds, area-weights, normalizes, clamps).
  Concatenating Face + Objects regions feeds it more boxes; the reduce is
  commutative, so merge order is irrelevant. (Slice 2 introduces the weighted
  formula.)
- Detector resolution: `:default` resolves to the Composite via
  `Transform.resolve_detector/1` (the `@default_detector` constant in
  `transform.ex` is repointed from `ImageVision` to `Composite`). Request/source/
  response/cache code continues to dispatch only through generic
  `ImagePipe.Transform` functions and must not name `Composite`, `ImageVision.Face`,
  or `ImageVision.Objects` (Boundary; enforced by `architecture_boundary_test`).
- **Face-assist is unchanged:** `{:smart, :face_assist}` still calls detection
  with `classes: ["face"]`, which routes to the Face child only. Its blend math,
  weight, and `[:transform, :detect, :blend]` event are untouched.

### Cache identity (class-aware)

`ImagePipe.Transform.detector_identity/2` becomes class-aware. **Both** class-
threading call sites must put the plan's detect classes into the opts handed to
the generic `Transform` facade (reviewer-verified to introduce no forbidden
boundary edge — request code touches only `Plan` + the generic `Transform`):

- `Request.Runner.put_detector_identity/2` (cache-key build) →
  `Keyword.put(opts, :classes, Plan.detect_classes(plan))` before
  `Transform.detector_identity(detector, opts)`.
- `ImagePipe.Plug.validate_detector_capability/2` (strict gate) → the same
  threading before `Transform.detector_available?(detector, opts)`.

The Composite then returns the identities of only the children that class set
routes to. Resulting identities:

| Request        | Children that run | Identity material        |
| -------------- | ----------------- | ------------------------ |
| `obj:face`     | Face              | `[Face id]` — **= today's key, continuity** |
| `obj:car`      | Objects           | `[Objects id]`           |
| `obj:face:dog` | Face + Objects    | `[Face id, Objects id]`  |
| `obj` / `obj:all` | Face + Objects | `[Face id, Objects id]`  |

Consequences this guarantees:

- Bumping the face model **does not** invalidate `obj:car` results (the face
  model can't change a car crop) — the key reflects response identity, per the
  cache guidelines. (Depends on the threading above actually landing.)
- The identity list order comes from the **fixed child order**, not the requested
  class order, so `obj:face:dog` and `obj:dog:face` produce an identical identity
  list (and `term_to_binary([:deterministic])` serializes it stably).
- Each child identity folds in `(repo, model_file/filename, min_score)`, since
  `min_score` changes which regions survive → changes the crop → changes the
  bytes. Identity assumes the model artifact is **immutable per `{repo,
  filename}`** (a mutable HF tag could change bytes under a stable key — same
  assumption the existing face detector already carries).
- Cache key carries the canonical *requested* class set (sorted); unknown classes
  that get dropped at runtime stay in the key (harmless over-keying — never
  serves wrong bytes, only an extra miss). No new cache-key data version bump
  (greenfield; reshape in place).

### Strict gate (`detector_required`)

`validate_detector_capability/2` (plug, pre-fetch) generalizes from face-only:

- Fires only when `detector_required: true` **and** the plan requests detection
  (`Plan.detect_classes/1 != nil`, true for `:all` and any class list).
- Availability is evaluated for the request's class set (threaded into the
  Composite's `available?`, as above). A 422-before-fetch is returned when a
  **real, supported, requested** class has no available detector.
- **Unknown classes never trigger the gate** — they route to no child, so there is
  no required-but-unavailable child; `available?` returns true and the request
  degrades to attention (it is not a 422).
- Graceful default (`detector_required: false`) unchanged: no available detector →
  attention fallback. Face-assist is never hard-rejected.

### Telemetry

- **`[:transform, :detect]`** stays the aggregate span (honest total detect
  duration). Metadata gains `requested_classes` and `effective_classes` (the
  post-routing set actually detected) so best-effort drops are observable. `result`
  aggregates across children: `:detected` if any child returned regions,
  `:no_regions` if all ran empty, `:unavailable`/`:error` on child failure.
- **`[:transform, :detect, :model]`** (new) — a nested span per child detector
  that runs. Metadata:
  - `detector` = the child *module name* (e.g.
    `ImagePipe.Transform.Detector.ImageVision.Objects`), for grouping.
  - `model` = the child's `identity/1` (for the bundled adapters,
    `{repo, filename, min_score}`). It is version-bearing, so the span shows which
    model version ran and changes when the model file changes. A model-artifact name
    is harmless, product-neutral public metadata — not a request/source/storage path
    or cache key — so emitting it does not breach the telemetry "no sensitive data"
    intent.
  - the routed `classes` subset (`:all` or list), `regions` (count), and honest
    inference duration (model inference is real eager work — legitimate compute
    timing, unlike libvips-lazy per-operation spans).
  - **Documented contract (no guard code):** a detector's `identity/1` appears in
    this span, so custom-detector authors should keep it free of secrets. We don't
    add machinery to defend against a detector that both encodes a secret in its
    identity *and* exports raw telemetry to an external sink — that's a far-fetched
    misuse, and the repo philosophy is to document the contract, not guard
    impossible misuse.
- **`[:transform, :detect, :skipped]`** unchanged (no detector configured),
  carrying `classes`.
- Metadata stays product-neutral and non-sensitive: module names, class strings,
  counts. No paths, URLs, signatures, or filenames.
- The opt-in default Logger and `telemetry.md` are updated for the new model span
  (the `detector` module name + the `model` = `identity/1`) and the
  requested/effective metadata, including the one-line "keep `identity/1` free of
  secrets" note in the custom-detector docs.

### Config & wiring

- Plug options unchanged: `detector` (`:default | nil | module`) and
  `detector_required` (boolean). No new model-tuning options.
- `:default` = `Composite[Face, Objects]` with image_vision default models and a
  per-child default `min_score`.
- **Warmup:** the warmup worker warms both children (face + objects), e.g. warm
  with `classes: :all`. Build/deploy alternative: `mix
  image_vision.download_models --detect` pre-fetches the RT-DETR object model
  (this *does* include it, unlike YuNet which the task omits). The RT-DETR model
  is ~175 MB, so cold-start is far heavier than faces — warmup matters much more
  here; document it.
- Custom detectors and the Composite remain the host's tuning path.

### Demo

Per the repo convention to keep the demo in sync with transform changes
(`demo/`):

- Add object-class gravity controls: a class multi-select (COCO-80 + an `all`
  option) plus the bare-`obj` form, wired into URL state alongside the existing
  face and smart-crop controls. Use the URL-facing (underscore) class spelling.
- Keep `detector: :default` wiring.

### Docs

- `docs/content-aware-gravity.md` — add the general object gravity section
  (multi-class, `all`/bare-`obj` includes faces, best-effort unknown-class drop,
  class-aware cache identity, underscore class spelling), and note `objw` is
  Slice 2. Mention RT-DETR cold-start/model-size and the `--detect` download task.
- `docs/imgproxy_support_matrix.md` — update the obj-gravity row: multi-class and
  `all` now supported; `objw` / `objects_position` still out (Slice 2 / out of
  scope). Keep the YuNet-vs-imgproxy-YOLO divergence notes; add the RT-DETR/COCO-80
  object model.
- `docs/telemetry.md` — document the per-model span (`detector` module name +
  `model` = the child's `identity/1`) and the requested/effective-classes metadata;
  add the one-line "keep custom `identity/1` free of secrets" note.

## Testing

Following the repo test guidelines (assert at boundaries the caller doesn't
control; no impossible-internal-misuse, name-policing, or parity-pin tests).
**All deterministic geometry/identity tests use `FakeDetector` (a real
`@behaviour` producer) injected via `detector:` — never the real ML model** — so
they run in the default lane and don't depend on model downloads or
nondeterministic inference.

- **Parser** (`option_grammar`/`plan_builder` tests): `obj:%c1:…:%cN`, bare
  `obj` → `:all`, `obj:all` → `:all`, `all` among classes → `:all`; both `g:` and
  `c:W:H:` forms; order-insensitivity of the class list. Flip the existing
  `plan_builder_test.exs` "rejects bare/all/multi-class object gravity" cases
  (currently asserting rejection) to acceptance — these are genuine behavior-change
  flips, not parity pins.
- **Planner mapping:** `tagged_gravity` emits `{:detect, :all}` / `{:detect,
  classes}`; parser/planner remains detector-vocabulary-free — assert via the
  `architecture_boundary_test` detector-module scan (extend the forbidden-globs to
  parser/plan for **detector-module references**, not a COCO-label denylist, which
  would itself leak vocabulary).
- **Composite unit tests** (driven by **fake child detectors**, not hand-built
  region lists): routing/partition by `supported_classes`; `:all` runs all
  children; best-effort drop of unclaimed classes; union `supported_classes`;
  class-aware `identity/1` (face-only vs objects-only vs both) and its **URL-order
  invariance** (`obj:face:dog` identity == `obj:dog:face` identity); class-aware
  `available?/1` including the all-unknown→`true` case. Assert observable output
  (merged region count / resulting focal point), not a private merge helper.
- **Wire-level Plug tests** (real `ImagePipe.call/2`, **decode the body**, inject
  FakeDetector):
  - A **non-face class** (e.g. `obj:car`) with a FakeDetector returning a corner
    box: decode and `refute` body-equality vs **both** a centered crop and a `g:sm`
    attention crop — proving the crop genuinely moved and did not silently fall back
    to attention (the central risk of this feature). Template: the `g:sm` pixel test
    in `imgproxy_wire_conformance_test.exs`.
  - A **no-geometry** `g:obj:…` variant (gravity without `rs:fill`/`c:`), covered
    separately per the guideline.
  - `obj:face:dog` / `obj:all` representative geometry.
  - **Gate triad** (Composite with Face available, Objects unavailable, under
    `detector_required: true`): `obj:face` → 200 (Face routes, available);
    `obj:car` → 422 **before** source fetch/cache (Objects routes, unavailable);
    `obj:unknownclass` → **not** 422 (dropped → degrades to attention/200).
  - Cache reuse for order-equivalent class lists; `Vary: Accept` unaffected.
- **Cache-key tests:** `obj:face` keys to **Face-child-identity-only** and is
  unchanged by an Objects/other-model identity bump (assert as a *structural
  invariant* — "face request's identity must not depend on the object model" — not
  a captured-hash parity pin); `obj:car` keys differ and are unaffected by a
  face-model identity bump; `obj:face:car` includes both; class-list
  canonicalization (sorted) yields a stable key regardless of URL order.
- **Telemetry tests:** aggregate `[:transform, :detect]` carries
  `requested_classes`/`effective_classes`; a per-model `[:transform, :detect,
  :model]` span is emitted per child that runs, with `detector` = module name and
  `model` = the child's `identity/1`; `:skipped` still fires with no detector.
- **Property tests:** parser order-insensitivity for class lists; cache-key
  canonicalization across class orderings.
- **Real-model lane (one `@tag :image_vision` coarse smoke test only):** a single
  test that exercises the live Objects adapter and asserts only *coarse*
  invariants — status 200, correct output dimensions, `result: :detected`
  telemetry — and a `supported_classes/1` sanity assert (non-empty, contains a
  known label like `"person"`, catching a wrong label list). **Never** assert exact
  pixels or exact box coordinates against the real model (nondeterministic across
  versions/platforms). Mirrors the existing tagged `image_vision_test.exs` pattern.

## Boundary / namespace compliance

- New modules live under `ImagePipe.Transform.Detector.*` (transform boundary);
  `Composite`, `ImageVision.Face`, `ImageVision.Objects`.
- The `Detector` behaviour and the generic `ImagePipe.Transform` entry points are
  the only detector surface exported; concrete adapter/Composite modules are not
  named by request/source/response/cache code. The class-threading at the gate and
  key-build touches only `Plan` + the generic `Transform` facade (no forbidden
  edge — reviewer-verified against `architecture_boundary_test`).
- Parser emits only product-neutral `{:detect, …}` guides; `all`-normalization and
  class-spelling normalization are isolated in the parser and the Objects adapter
  respectively; no detector vocabulary leaks into `parser`, `request`, `cache`, or
  `plan`.

## Risks / assumptions

1. **`Image.Detection.detect/2` API — CONFIRMED** against installed `image_vision
   0.4.0`: function exists (`detection.ex:131`), returns
   `%{label, score, box: {x,y,width,height}}` (abs px, sorted desc), options
   `min_score`/`repo`/`filename`, COCO-80 via the public `Image.Detection.classes/0`.
   Use `:filename` (not `:model_file`), omit `:nms_iou`.
2. **ML nondeterminism (test risk).** Real-model detection (box coords, score
   ordering) varies across versions/platforms, and the `@tag :image_vision` lane
   downloads models on first detect. Mitigation: all geometry/identity/pixel wire
   tests inject `FakeDetector`; the real model is exercised by exactly one coarse,
   tagged smoke test asserting only status/dimensions/`:detected` (no exact
   pixels). See § Testing.
3. **Model download & size.** RT-DETR pulls a ~175 MB model on first use (a ~45 MB
   quantized variant exists via `filename:`). `mix image_vision.download_models
   --detect` covers it (unlike YuNet); the warmup worker is the runtime path. Cold
   start is far heavier than faces — warmup guidance is more important here.
4. **Both-models cost for `:all`.** `obj`/`obj:all` runs two models. Acceptable and
   intended; the per-model telemetry span surfaces the cost.
5. **Equal-weight default bias.** Plain `obj:all` on a person photo biases toward
   the larger `person` box, not the face. This is the faithful imgproxy
   equal-weight default; face-centric crops use `obj:face` (Slice 1) or `objw`
   (Slice 2). Documented, not a bug.
6. **Class-threading is load-bearing.** The class-aware identity/availability story
   works only if `Plan.detect_classes(plan)` is threaded into opts at **both** the
   plug gate and the runner key-build. Without it, `obj:car` would be invalidated
   by a face-model bump and the gate could wrongly 422 a routable request. Covered
   by the cache-key and gate-triad tests.
