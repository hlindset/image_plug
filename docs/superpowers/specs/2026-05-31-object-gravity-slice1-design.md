# Object-oriented gravity — Slice 1: general object gravity (equal-weight)

**Status:** approved design, pre-implementation
**Date:** 2026-05-31
**Builds on:** the smart-gravity / ML-detection seam landed in #130 (`g:sm`,
`g:obj:face`, face-assist, the `ImagePipe.Transform.Detector` behaviour, the
bundled `ImageVision` YuNet adapter, `focal_from_regions`, detector identity in
the cache key, the `detector_required` gate, `[:transform, :detect]` telemetry,
`Detector.Warmup`).

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
   span has.
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
  evaluate per-request availability.
- `detect/2`'s `classes` opt is now `:all | [String.t()]`. `:all` means "every
  region this detector can produce" (no class filter).

This is a real `@impl` behaviour callback, not a duck-typing probe — consistent
with the repo's "call the callback, let missing callbacks raise" stance.

### Adapters: split the bundled `ImageVision` into Face + Objects

The current single `ImagePipe.Transform.Detector.ImageVision` (YuNet face) is
split into two product-neutral adapter modules under the same namespace:

- **`ImagePipe.Transform.Detector.ImageVision.Face`**
  - Wraps `Image.FaceDetection.detect/1` (YuNet), as today.
  - `supported_classes(_) → ["face"]`.
  - `detect/2`: returns face regions for `classes == ["face"]` or `:all`; an empty
    routed subset returns `{:ok, []}`.
  - `available?/1`: `Code.ensure_loaded?(Image.FaceDetection)`, as today.
  - `identity/1`: `{__MODULE__, {repo, model_file, min_score}}`.
  - `warmup/1`: blank-image detect to trigger model load, as today.

- **`ImagePipe.Transform.Detector.ImageVision.Objects`** (new)
  - Wraps `Image.Detection.detect/2` (RT-DETR, COCO-80). **Verify the exact
    function/option names and the COCO-80 label list against the installed
    `image_vision` before wiring** (assumed: returns `%{label, score, box:
    {x,y,width,height}}` abs pixels sorted by score; opts `min_score:`, `repo:`,
    `filename:`).
  - `supported_classes(_) → <COCO-80 labels>` (owned by this adapter — the
    parser/planner must never enumerate them).
  - `detect/2`: runs detection, filters results to the routed classes (or returns
    all for `:all`), applies `min_score`.
  - `available?/1`: presence check for `Image.Detection`.
  - `identity/1`: `{__MODULE__, {repo, filename, min_score}}`.
  - `warmup/1`: blank-image detect to trigger model load.

### `ImagePipe.Transform.Detector.Composite` (new)

A product-neutral router holding an **ordered list of child detectors**.

- **Construction:** `:default` resolves to `Composite[Face, Objects]` (in that
  order, so face wins ties in ordered merges if any). Children carry their own
  default opts (models, `min_score`).
- **`detect(image, opts)`** where `opts[:classes]` is `:all | [String.t()]`:
  - `:all` → run **every** child with `classes: :all`; merge all regions.
  - list → for each child, compute `routed = requested ∩ child.supported_classes`;
    run only children with a non-empty `routed` (passing `classes: routed`); merge
    regions. Classes claimed by no child are **dropped** (best-effort).
  - Merge is region-list concatenation (order-independent for the equal-weight
    area centroid). De-duplication of overlapping `person`/`face` is **not**
    performed — both contribute by area; Slice 2 weights arbitrate.
- **`supported_classes(opts)`** → union of children's `supported_classes`.
- **`available?(opts)`** → evaluated for the request's class set
  (`opts[:classes]`): the children that the class set routes to must be available.
  `:all` routes to all children → all must be available. Used by the strict gate.
- **`identity(opts)`** → the identities of only the children the request's class
  set routes to, as an ordered list (see § Cache identity). Class-aware.

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
- `ImagePipe.Plan.detect_classes/1` returns `:all | nonempty_list(String.t()) |
  nil`.
- `key_data` guide encoding:
  - `{:detect, :all}` → `[type: :detect, classes: :all]`
  - `{:detect, classes}` → `[type: :detect, classes: Enum.sort(classes)]`

### Parser (imgproxy) — stays vocabulary-free

In `lib/image_pipe/parser/imgproxy/`:

- `option_grammar.ex` already parses `g:obj:…` and `c:W:H:obj:…` into
  `{:obj, classes}` with no parse-time validation. Confirm it accepts the empty
  class list (bare `g:obj`) and multi-class lists; both `g:` and `c:W:H:` forms.
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

- `detect_crop` handles `{:detect, :all}` in addition to the class-list form,
  threading `classes` (`:all` or list) into the detector opts.
- `focal_from_regions` is **unchanged** — equal-weight area centroid. (Slice 2
  introduces the weighted formula.)
- Detector resolution: `:default` resolves to the Composite via
  `Transform.resolve_detector/1`. Request/source/response code continues to
  dispatch only through generic `ImagePipe.Transform` functions and must not name
  `Composite`, `ImageVision.Face`, or `ImageVision.Objects` directly (Boundary).
- **Face-assist is unchanged:** `{:smart, :face_assist}` still calls detection
  with `classes: ["face"]`, which routes to the Face child only. Its blend math,
  weight, and `[:transform, :detect, :blend]` event are untouched.

### Cache identity (class-aware)

`ImagePipe.Transform.detector_identity/2` becomes class-aware: the cache-key
build site (`Request.Runner`) threads the plan's detect classes
(`Plan.detect_classes/1`) into it, and the Composite returns the identities of
only the children that class set routes to.

Resulting identities:

| Request        | Children that run | Identity material        |
| -------------- | ----------------- | ------------------------ |
| `obj:face`     | Face              | `[Face id]` — **= today's key, continuity** |
| `obj:car`      | Objects           | `[Objects id]`           |
| `obj:face:dog` | Face + Objects    | `[Face id, Objects id]`  |
| `obj` / `obj:all` | Face + Objects | `[Face id, Objects id]`  |

Consequences this guarantees:

- Bumping the face model **does not** invalidate `obj:car` results (the face
  model can't change a car crop) — the key reflects response identity, per the
  cache guidelines.
- Each child identity folds in `(repo, model_file/filename, min_score)`, since
  `min_score` changes which regions survive → changes the crop → changes the
  bytes.
- Cache key carries the canonical *requested* class set (sorted); unknown classes
  that get dropped at runtime stay in the key (harmless over-keying — never
  serves wrong bytes). No new cache-key data version bump (greenfield; reshape in
  place).

### Strict gate (`detector_required`)

`validate_detector_capability/2` (plug, pre-fetch) generalizes from face-only:

- Fires only when `detector_required: true` **and** the plan requests detection.
- Availability is evaluated for the request's class set (threaded into the
  Composite's `available?`). A 422-before-fetch is returned when a **real,
  supported, requested** class has no available detector.
- **Unknown classes never trigger the gate** — they are dropped (not an
  availability failure). If a request's classes all drop to nothing, it degrades
  to attention like any other no-detection case (it is not a 422).
- Graceful default (`detector_required: false`) unchanged: no available detector →
  attention fallback. Face-assist is never hard-rejected.

### Telemetry

- **`[:transform, :detect]`** stays the aggregate span (honest total detect
  duration). Metadata gains `requested_classes` and `effective_classes` (the
  post-routing set actually detected) so best-effort drops are observable. `result`
  aggregates across children: `:detected` if any child returned regions,
  `:no_regions` if all ran empty, `:unavailable`/`:error` on child failure.
- **`[:transform, :detect, :model]`** (new) — a nested span per child detector
  that runs, with metadata: `detector` (child identity), `classes` (the routed
  subset, `:all` or list), `regions` (count), and honest inference duration (model
  inference is real eager work — legitimate compute timing).
- **`[:transform, :detect, :skipped]`** unchanged (no detector configured),
  carrying `classes`.
- Metadata stays product-neutral and non-sensitive: module names, class strings,
  counts. No paths, URLs, signatures, or filenames.
- The opt-in default Logger and `telemetry.md` are updated for the new model span
  and the requested/effective metadata.

### Config & wiring

- Plug options unchanged: `detector` (`:default | nil | module`) and
  `detector_required` (boolean). No new model-tuning options.
- `:default` = `Composite[Face, Objects]` with image_vision default models and a
  per-child default `min_score`.
- **Warmup:** the warmup worker warms both children (face + objects). Update the
  default wiring/docs so a single warmup pre-loads both models (e.g. warm with
  `classes: :all`, or warm each child).
- Custom detectors and the Composite remain the host's tuning path.

### Demo

Per the repo convention to keep the demo in sync with transform changes
(`demo/`):

- Add object-class gravity controls: a class multi-select (COCO-80 + an `all`
  option) plus the bare-`obj` form, wired into URL state alongside the existing
  face and smart-crop controls.
- Keep `detector: :default` wiring.

### Docs

- `docs/content-aware-gravity.md` — add the general object gravity section
  (multi-class, `all`/bare-`obj` includes faces, best-effort unknown-class drop,
  class-aware cache identity), and note `objw` is Slice 2.
- `docs/imgproxy_support_matrix.md` — update the obj-gravity row: multi-class and
  `all` now supported; `objw` / `objects_position` still out (Slice 2 / out of
  scope). Keep the YuNet-vs-imgproxy-YOLO divergence notes; add the RT-DETR/COCO-80
  object model.
- `docs/telemetry.md` — document the per-model span and the
  requested/effective-classes metadata.

## Testing

Following the repo test guidelines (assert at boundaries the caller doesn't
control; no impossible-internal-misuse, name-policing, or parity-pin tests):

- **Parser** (`option_grammar`/`plan_builder` tests): `obj:%c1:…:%cN`, bare
  `obj` → `:all`, `obj:all` → `:all`, `all` among classes → `:all`; both `g:` and
  `c:W:H:` forms; order-insensitivity of the class list; the former `["face"]`
  gate no longer rejects other classes.
- **Planner mapping:** `tagged_gravity` emits `{:detect, :all}` / `{:detect,
  classes}`; parser remains vocabulary-free (no COCO import — assert via the
  architecture boundary test, the only place source-scanning is allowed).
- **Composite unit tests:** routing/partition by `supported_classes`, merge,
  union `supported_classes`, best-effort drop of unclaimed classes, `:all` runs
  all children, class-aware `identity/1` (face-only vs objects-only vs both),
  class-aware `available?/1`.
- **Wire-level Plug tests** (real `ImagePipe.call/2`, decode the body): `obj:car`,
  `obj:face:dog`, and `obj:all` produce expected geometry vs a plain/attention
  baseline; `detector_required` returns 422 **before** source fetch/cache access
  when a supported class has no available detector; cache reuse for
  order-equivalent class lists; `Vary: Accept` unaffected.
- **Cache-key tests:** `obj:face` key equals the pre-change face key (continuity);
  `obj:car` key differs and is unaffected by a face-model identity bump;
  `obj:face:car` includes both; class-list canonicalization (sorted) yields a
  stable key regardless of URL order.
- **Telemetry tests:** aggregate `[:transform, :detect]` carries
  `requested_classes`/`effective_classes`; a per-model `[:transform, :detect,
  :model]` span is emitted per child that runs; `:skipped` still fires with no
  detector.
- **Property tests:** parser order-insensitivity for class lists; cache-key
  canonicalization across class orderings.

## Boundary / namespace compliance

- New modules live under `ImagePipe.Transform.Detector.*` (transform boundary);
  `Composite`, `ImageVision.Face`, `ImageVision.Objects`.
- The `Detector` behaviour and the generic `ImagePipe.Transform` entry points are
  the only detector surface exported; concrete adapter/Composite modules are not
  named by request/source/response code.
- Parser emits only product-neutral `{:detect, …}` guides; `all`-normalization is
  isolated in the imgproxy parser.
- No detector vocabulary leaks into `parser`, `request`, `cache`, or `plan`.

## Risks / assumptions to verify during implementation

1. **`Image.Detection.detect/2` API** — confirm exact function name, option names
   (`min_score`/`repo`/`filename`), return shape, and the COCO-80 label list
   against the installed `image_vision` before wiring the Objects adapter. The
   region shape is assumed identical to the existing `Detector.region`
   (`%{label, score, box: {x, y, width, height}}`, abs pixels, sorted by score).
2. **`ortex`/model download** — RT-DETR pulls a model on first use, like YuNet.
   The warmup worker must cover it; the first cold object request otherwise pays
   the download. Document alongside the existing face warmup guidance.
3. **Both-models cost for `:all`** — `obj`/`obj:all` runs two models. Acceptable
   and intended; the per-model telemetry span surfaces the cost.
4. **Equal-weight default bias** — plain `obj:all` on a person photo biases toward
   the larger `person` box, not the face. This is the faithful imgproxy
   equal-weight default; face-centric crops use `obj:face` (Slice 1) or `objw`
   (Slice 2). Documented, not a bug.
