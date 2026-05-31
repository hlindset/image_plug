# Smart gravity & the ML detection seam — design

Status: accepted (implemented) (v3 — revised after two adversarial review cycles; see [Review cycle](#review-cycle))
Date: 2026-05-30
Issue: [#34 Add smart gravity and object-aware crop anchors](https://github.com/hlindset/image_plug/issues/34)
Plan: [docs/superpowers/plans/2026-05-31-smart-gravity.md](../plans/2026-05-31-smart-gravity.md)

## Summary

Add content-aware crop anchoring to ImagePipe, closing the last gap in the
imgproxy cover/crop story. The increment delivers three user-visible
capabilities, all built on one product-neutral detector seam:

1. **`g:sm` → libvips attention smart crop** — deterministic, no dependency.
2. **`g:obj:face` → face-aware gravity** — anchors the crop on detected faces
   via the optional `image_vision` dependency, falling back to attention.
3. **`smart_crop_face_detection` config → face-assisted `g:sm`** — when
   configured, `g:sm` blends the attention point with detected faces (imgproxy
   Pro `IMGPROXY_SMART_CROP_FACE_DETECTION`).

Face detection is the **first member** of a general object-detection seam.
General object classes, multi-class, weighted (`objw`), and `objects_position`
are deferred (see [Out of scope](#out-of-scope)), but the seam and the
product-neutral plan representation are designed so they are additive.

## Goals

- Faithful imgproxy compatibility for `g:sm` and `g:obj:face`.
- A product-neutral, host-implementable `Detector` behaviour that is the
  foundation for the broader ML compatibility program.
- Optional ML dependency: default builds pull no ONNX/ML runtime; hosts opt in.
- Deterministic, model-free unit tests via a dependency-injected detector.
- Cache correctness when detection influences output bytes.

## Non-goals

- Bit-identical parity with imgproxy's ML output (different models, different
  gravity-mode math, different attention⊕face blend; see [Divergences](#divergences)).
- General object-class gravity, weights, and object positioning (deferred).

## Background & constraints

Relevant current code:

- `ImagePipe.Plan.Operation.CropGuided` ([crop_guided.ex](../../../lib/image_pipe/plan/operation/crop_guided.ex)) —
  `guide` union: `anchor() | {:anchor, h, v} | {:focal, {:ratio,..}, {:ratio,..}}`.
- `ImagePipe.Plan.Operation.Resize` (cover) carries the same `guide`; both the
  cover path and the explicit-crop path translate it through
  `tagged_executable_gravity/1` in
  `ImagePipe.Transform.PlanExecutor` ([plan_executor.ex](../../../lib/image_pipe/transform/plan_executor.ex)).
  **At the transform/executor layer**, a new guide variant is honored by both
  cover-resize and `c:` crop with no extra wiring. **At the parser layer it is
  not free** — see §4.
- `ImagePipe.Transform.Operation.Crop` ([crop.ex](../../../lib/image_pipe/transform/operation/crop.ex)) —
  resolves transform gravity `{:anchor,h,v}` / `{:fp,x,y}` to a crop origin via
  `Image.crop/5`; `{:fp,x,y}` is range-guarded (`0.0..1.0`) and the origin is
  clamped in-bounds.
- `ImagePipe.Transform.State` ([state.ex](../../../lib/image_pipe/transform/state.ex)) —
  carries only `image` + `debug`; the `execute/2` operation callback gets no
  runtime options.
- `ImagePipe.Plan.KeyData` ([key_data.ex](../../../lib/image_pipe/plan/key_data.ex)) —
  `guide_data/1` is a **closed clause set, no catch-all** (unknown guides raise);
  `data/1` recurses on geometry coordinates and has **no string clause**.
- `ImagePipe.Cache.Key.build/4` ([key.ex](../../../lib/image_pipe/cache/key.ex))
  folds `%Plan{}` material plus a narrow `opts` allowlist
  (`@plan_key_option_keys` in [cache.ex](../../../lib/image_pipe/cache.ex)) — but
  allowlisted opts are only read where `Key.build` explicitly threads them
  (currently the `output` sub-key).
- `ImagePipe.Parser.Imgproxy.PlanBuilder`
  ([plan_builder.ex](../../../lib/image_pipe/parser/imgproxy/plan_builder.ex)) —
  rejects `g:sm` at **two** clauses (`:196` top-level, `:199` `%CropRequest{}`).
- `ImagePipe.Parser.Imgproxy.OptionGrammar`
  ([option_grammar.ex](../../../lib/image_pipe/parser/imgproxy/option_grammar.ex)) —
  gravity values parsed by **distinct** functions `parse_gravity/2` and
  `parse_crop_gravity/1`; crop arg tokenization is `parse_crop/2`.
- `ImagePipe.Transform` ([transform.ex](../../../lib/image_pipe/transform.ex)) —
  `use Boundary`, explicit `exports:`, `deps: [Plan, Telemetry]`.
- `ImagePipe.Application` ([application.ex](../../../lib/application.ex)) — boots
  before plug mounts; `deps: [Output, Request]` (no `Transform`).
- `ImagePipe.Telemetry.DefaultLogger` ([logger.ex](../../../lib/image_pipe/telemetry/logger.ex)) —
  an explicit event map per group (e.g. `transform: [[:transform, :execute],
  [:transform, :operation]]`); a new span is invisible unless registered here.
- `Vix.Vips.Operation.smartcrop/4` returns `{:ok, {image, %{"attention-x": _,
  "attention-y": _}}}` — the attention point **is** readable (verified by probe).
  Note the keys are **hyphenated atoms** (`:"attention-x"`), in input-image
  pixels.

Architecture rules that shape this design (`CLAUDE.md`): product-neutral plan,
parser dialect terms must not leak; host-implementable behaviour returns are
validated structurally but trusted internal callbacks are not duck-typed;
request/source/response dispatch through generic `ImagePipe.Transform` and must
not name concrete transform modules; cache key includes inputs that change
successful encoded bytes (not safety limits), reshaped in place for greenfield.

## Design

### 1. Product-neutral plan representation

Extend the shared `guide` union (`CropGuided` and `Resize`) with:

- `:smart` — saliency/attention strategy (libvips attention).
- `{:smart, :face_assist}` — attention point **blended** with detected faces
  (§5); never hard-rejects (an enhancement to an always-valid attention crop).
- `{:detect, classes}` — anchor on detected objects of `classes`. **`classes`
  is a list of validated strings** (e.g. `["face"]`), matching `region.label`'s
  type and `image_vision`'s string labels. This increment accepts only
  `["face"]` (exact match `"face"`); anything else is rejected at parse. Strings
  end-to-end remove any `String.to_atom/1` temptation as the accepted set widens.

`@type guide` gains these three forms. No new operation struct (Approach A);
geometry stays centralized in `tagged_executable_gravity/1`.

### 2. The `Detector` seam

A product-neutral, host-implementable behaviour under the transform boundary:

```elixir
defmodule ImagePipe.Transform.Detector do
  @moduledoc "Host-implementable content detection for content-aware gravity."

  @type region :: %{label: String.t(), score: float(), box: {number, number, number, number}}

  @doc "Detect regions of interest. `opts` carries `:classes`."
  @callback detect(image :: Vix.Vips.Image.t(), opts :: keyword()) ::
              {:ok, [region]} | {:error, term()}

  @doc "Whether the detector can run now (e.g. optional dep loaded)."
  @callback available?(opts :: keyword()) :: boolean()

  @doc "Stable identity for cache-key material: {module, term}."
  @callback identity(opts :: keyword()) :: {module(), term()}

  @doc "Optionally pre-load models so the first request doesn't pay download cost."
  @callback warmup(opts :: keyword()) :: :ok | {:error, term()}
  @optional_callbacks warmup: 1
end
```

- `available?/1` and `identity/1` take `opts` (not arity 0) so a future host
  adapter that selects a model from config can answer without a global. The face
  adapter ignores `opts`.

**Default adapter** `ImagePipe.Transform.Detector.ImageVision`:

- Wraps `Image.FaceDetection.detect/2` for `"face"`. **Required, not a
  preference:** `image_vision`'s general object detector (`Image.Detection`,
  default `rtdetr_r50vd`) uses COCO classes with **no `face` class**; faces come
  from a separate OpenCV YuNet model (~340 KB), downloaded independently of the
  ONNX default-models set.
- `Image.FaceDetection.detect/2` returns a **bare list**
  `[%{box: {x,y,w,h}, score, landmarks}]` — no `{:ok, …}` wrapper, **no `:label`
  key**, boxes **absolute-pixel, top-left**, and it **raises** rather than
  returning `{:error,_}`. The adapter therefore: calls it inside a **narrow
  `rescue`** (justified — this is a host/optional-dep runtime boundary, the
  sanctioned exception to "no catch-all rescue"; raises map to
  `{:error, {:detector, reason}}`), wraps the list in `{:ok, …}`, synthesizes
  `label: "face"`, and drops `landmarks` (not part of `region`).
- Optional-dep handling: `image_vision` is **not** a declared dep;
  `@compile {:no_warn_undefined, Image.FaceDetection}` silences the compiler;
  `available?/1` is `Code.ensure_loaded?(Image.FaceDetection)`. (ImagePipe does
  not currently run dialyzer; a `.dialyzer_ignore.exs` entry is added only if/
  when dialyzer is introduced.)
- `identity/1` returns `{__MODULE__, {repo, model_file}}` from the configured
  (or default) YuNet `{ "opencv/face_detection_yunet",
  "face_detection_yunet_2023mar.onnx" }` — the dated filename **is** the version
  token (`image_vision` exposes no version API). Returns
  `{__MODULE__, :unavailable}` when the dep is absent.

**Detector return validation (host boundary).** `PlanExecutor`/`Crop` validate
the *structural shape* of `{:ok, regions}` like `Source.valid_resolved?/1`: each
`region` is a map with a 4-number `box` tuple (and `label`/`score` present);
anything else maps to `{:error, {:detector, :invalid_adapter_result}}` feeding
the fallback ladder (§5). Semantic plausibility (score range, box-in-image) is
**not** asserted here — out-of-image boxes are *dropped* geometrically (§5), per
the validation guidelines. The producer tests this references are for the **DI
fake adapter** (in-repo), not a guarantee about third-party `image_vision`.

### 3. Configuration

- **Transform-runtime (product-neutral)** — top-level plug options, validated
  via the existing `ImagePipe.Plug` options path:
  - `detector` — a module implementing `Detector`. Default resolves to
    `ImagePipe.Transform.Detector.ImageVision` **inside the transform boundary**
    (the plug passes `detector: :default` / `nil`; `PlanExecutor` resolves it),
    so no request/plug code names the concrete adapter.
  - `detector_required` — boolean, default `false`. `false` → graceful fallback;
    `true` → reject `{:detect,_}` before side effects.
- **imgproxy-parser dialect knob** — under `imgproxy:`:
  - `smart_crop_face_detection` — boolean, default `false`. When `true`, the
    parser translates `g:sm` to `{:smart, :face_assist}` instead of `:smart`.

### 4. Parser mapping (imgproxy)

Not free at the parser layer; multiple distinct paths change.

`OptionGrammar`:

- `parse_gravity/2`: add `obj` value parsing — `g:obj:%class[:%class...]`. All
  tail tokens are **class names** (never offsets; imgproxy offsets are the
  separate `objects_position` option). Produces e.g. `{:obj, classes}`.
- `parse_crop/2` **and** `parse_crop_gravity/1`: crop gravity "accepts the same
  values as gravity", so `c:W:H:sm` and `c:W:H:obj:face` are valid.
  `c:256:256:obj:face` is a 4+ token crop arg list matching **none** of the
  current `parse_crop/2` clauses → add variadic `obj`-tail handling in both the
  crop tokenizer and `parse_crop_gravity/1`.
- Do **not** route `obj`/`sm` through the shared `@gravity_anchors` anchor
  parser, or they leak into `extend`/`extend_ar` gravity (which must keep
  rejecting `sm`/`obj`/`objw`).

`PlanBuilder` (replace **both** `:sm` rejections, `:196` and `:199`):

- `:sm` → `:smart`, or `{:smart, :face_assist}` when `smart_crop_face_detection`.
- `{:obj, ["face"]}` (single exact `face`) → `{:detect, ["face"]}`.
- `{:obj, []}` (**bare `g:obj` = "all"**), `{:obj, ["all"]}`, multi-class,
  `objw` → `{:error, {:unsupported_gravity, …}}`. The bare/empty and `all` forms
  must be **explicitly** rejected (not caught by a multi-class check).
- `objects_position` / `obj_pos` / `op` are top-level options, not gravity
  values; they remain rejected as unknown options before side effects (all three
  aliases). No new "recognized-but-unsupported value" parsing is added.

### 5. Execution & fallback

`Transform.State` gains `detector` (`nil | module`) and `detector_required`
(bool); its moduledoc is updated to note injected runtime config.
**`PlanExecutor.execute/3` populates these from `opts`** — the request layer's
`%State{image: image}` construction in `Processor` stays detector-free, so
request code never learns detector semantics. The `execute(operation, state)`
callback signature is unchanged.

`tagged_executable_gravity/1` maps the new plan guides to transform intents.
`Crop.execute/2`:

- **`:smart`** → `Vix.Vips.Operation.smartcrop/3` (attention) on the
  cover-resized image at the target window size. (Not `Image.thumbnail`, which
  fuses resize+crop; not `Image.crop`, which has no `:attention`.)
- **`{:detect, classes}`** → `state.detector.detect(image, classes: classes)`:
  - `{:ok, [_|_] = regions}` (after structural validation) → drop any region
    whose `box` is non-finite / out-of-image; from survivors compute the
    **area-weighted centroid** → `{:fp, x, y}` → existing focal crop. (Anchor a
    target-size window on the faces; do **not** zoom-to-face — matching imgproxy
    `obj` gravity, unlike the reference's `crop_largest`.)
  - `{:ok, []}` / all regions dropped → fall back to `:smart`.
  - `{:error, _}` (runtime / `{:detector, :invalid_adapter_result}`) → graceful
    fallback to `:smart`; or surface the error when `detector_required`.
  - `state.detector == nil` (host set `detector: nil`, `detector_required:
    false`) → fall back to `:smart`. A real host-reachable state with defined
    behavior (no duck-typing probe; a plain `nil` clause).
- **`{:smart, :face_assist}`** → obtain the attention point from `smartcrop`'s
  `attention_x/attention_y` (normalized to `0.0..1.0`); run face detection:
  - faces survive validation → **blend**: `P = (1-w)·A + w·F`, where `A` is the
    attention point, `F` the area-weighted face centroid, and `w` a
    face-favoring weight (our chosen default, e.g. `0.7`, documented as an
    approximation — imgproxy's internal combination is unspecified). `P` →
    `{:fp, x, y}` → focal crop.
  - no faces / dropped / `{:error,_}` / `detector == nil` / unavailable → pure
    attention (`:smart`). **Never hard-rejects**, regardless of
    `detector_required`.

**Strict-mode pre-fetch gate.** When `detector_required: true`, the validated
plan contains a `{:detect,_}` guide, and `detector.available?(opts) == false`,
reject **before source fetch or cache access** — alongside
`ImagePipe.Plug.do_call/1`'s `validate_client_plan/1` →
`Transform.validate_prefetch_safe_plan/1`, which precedes both `Source.resolve`
and `Runner.run` (cache lookup + fetch). The gate reads the guide through a
**new generic accessor `ImagePipe.Plan.detect_classes/1 :: [String.t()] | nil`**
owned by the `Plan` boundary, so no request/plug code names `CropGuided`.
`{:smart, :face_assist}` is never gated.

### 6. Cache key

The new guides must be serialized into the key, and detector identity threaded
as config-data. Three concrete changes (the allowlist alone is **not** enough):

- **`KeyData.guide_data/1` gains clauses** for `:smart`, `{:smart, :face_assist}`,
  and `{:detect, classes}`, serializing each **distinctly**. `{:detect, classes}`
  emits its `classes` as a **terminally-serialized sorted string list**
  (e.g. `[type: :detect, classes: Enum.sort(classes)]`) — it must **not** route
  `classes` back through `data/1`, which has no string clause and would raise.
- **`Key.build`/`plan_material` must read the threaded identity.** The request
  layer (which holds the resolved detector) **conditionally injects**
  `detector.identity(opts)` as an opaque `{module, term}` tuple into `opts`
  **only when** `Plan.detect_classes/1` is non-nil **or** the plan carries
  `{:smart,:face_assist}` (the condition lives at the injection site, not the
  static allowlist). A new key is added to `@plan_key_option_keys` **and**
  `plan_material/2` is edited to fold that tuple into the key data — extending
  the allowlist alone is inert (the value would never be read). The cache
  boundary sees only an opaque tuple and never names `Detector`.
- **Availability must enter the key.** `identity(opts)` is evaluated for every
  `{:detect,_}`/`{:smart,:face_assist}` plan **irrespective of `available?`**,
  returning `{module, :unavailable}` when the dep is absent. So a face-assist
  request with the dep absent (→ pure attention) keys differently from
  dep-present (→ blended) — preventing different-bytes/same-key across
  deployments.
- Plain `:smart` adds no identity material — deterministic for a fixed libvips;
  libvips-version keying is the orthogonal, already-tracked concern
  [#43](https://github.com/hlindset/image_plug/issues/43).
- Greenfield: reshape key data in place; no `@transform_key_data_version` bump.

### 7. Telemetry

Detection is **eager ML compute**, unlike lazy libvips ops, so its time must not
be silently absorbed into the per-operation `[:transform, :operation]` span
(documented as construction-only) or the coarse `[:transform, :execute]` span.

- Emit a `:telemetry.span/3`-style `[:transform, :detect]` span
  (`:start`/`:stop`/`:exception`) around the `detector.detect/2` call, with
  honest duration; warmup may emit `[:transform, :detect, :warmup]` so hosts can
  observe cold-start cost they're warned about in §10.
- **Register the new event(s) in `DefaultLogger`'s event map** ([logger.ex](../../../lib/image_pipe/telemetry/logger.ex)),
  or the span fires but is invisible to the bundled logger.
- Metadata is product-neutral and non-sensitive — detected `box`/`label`/`score`
  derive from the public request image (emittable by default, like the existing
  operation `:params` dump). **Never** put source URLs, cache keys, detector
  model file paths, or credentials in the span name, measurements, or metadata.

### 8. Boundary & namespaces

- `Detector`, `Detector.ImageVision`, and `Detector.Warmup` live in the
  transform boundary; **export `Detector` and `Detector.Warmup`** (the
  `ImageVision` adapter is referenced only inside the boundary, via §3 default
  resolution, so it need not be exported). Transform `deps:` stay
  `[Plan, Telemetry]` (external `Image.*` is not an in-app boundary).
- The detector reaches execution as config data, threaded
  request → `execute_plan/3` opts → `State`; `PlanExecutor` trusts the validated
  module and calls `detect/2` directly (no duck-typing probe).
- **Architecture tests (three):** (1) add `Detector*` module names to the
  forbidden-reference set so request/source/response/cache can't name them;
  (2) **extend `@request_source_response_globs` to include
  `lib/image_pipe/plug.ex`** (mandatory — the strict gate lives in `plug.ex`,
  which is in no glob today, so a `CropGuided` match there would otherwise pass)
  so the gate is forced to use `Plan.detect_classes/1`; (3) a `PlanBuilder`
  **producer test** proving no dialect gravity term (`{:obj,_}`, `:sm`) escapes
  into the Plan.

### 9. Demo & docs

- `demo/` imgproxy controls + URL state gain `sm` and `obj:face` gravity options
  (project rule: demo updated in the same change).
- `docs/imgproxy_support_matrix.md` updates — fix stale rows, don't just add:
  - Add a `gravity:obj:face` ✅ row; **downgrade `gravity:obj` to ⚠️ Partial**
    ("face only; bare `obj`/`all`/multi-class/`objw` rejected"). Not ✅.
  - `gravity:sm` ✅; rewrite the stale `crop` row ("Planning rejects smart
    gravity" — now false).
  - `IMGPROXY_SMART_CROP_FACE_DETECTION` ✅ (config) **with a divergence marker**
    on the row.
  - **Replace** (not merely add beside) the blanket `IMGPROXY_OBJECT_DETECTION_*`
    and `IMGPROXY_SMART_CROP_*` wildcard ⭕ lines, breaking out
    `IMGPROXY_OBJECT_DETECTION_GRAVITY_MODE`, `…_FALLBACK_TO_SMART_CROP`,
    `IMGPROXY_SMART_CROP_ADVANCED*`, and confidence/NMS thresholds as ⭕ rows
    with notes — the wildcards become self-contradictory once part of the
    surface ships.
  - Annotate the `crop_objects | co` row with the `co`↔`contrast` alias
    divergence (and optionally cross-note on the `contrast` row).

### 10. Operational notes: model distribution & latency

`image_vision` downloads weights on first call and caches on disk.

- **Readiness vs availability.** `available?/1` (cheap `Code.ensure_loaded?`)
  does **not** mean weights are present. Warmup is operational; ImagePipe never
  blocks boot on a download. Strict mode guarantees *capability*, not latency.
- **Cost is bounded to cache misses** — detection runs only when producing a
  response.
- **No per-request ML ceiling yet.** Until
  [#49](https://github.com/hlindset/image_plug/issues/49) lands, a cold
  `detect/2` can block on a download; a host enabling `detector_required` in
  prod without warmup can see request #1 hang. Documented risk; not in this
  increment.
- **Face is cheap on weights (~340 KB YuNet)** but the *dependency closure* is
  not: `image_vision` pulls `ortex` (Rust ONNX runtime), `nx`, etc. So the dep
  is **lane-scoped**, not unconditional (§Testing).
- **Build-time prefetch for faces uses `ImageVision.ModelCache.fetch!(repo,
  filename)` for the YuNet repo** — **not** `mix image_vision.download_models`,
  which excludes FaceDetection. Pair it with `Detector.Warmup` (§11).

### 11. Eager model warmup (optional)

Host-owned and opt-in (avoids a second runtime config path; `Application` boots
before plug mounts and cannot see plug-init detector config). ImagePipe ships the
capability; the host wires it into **their** tree with the same detector config
they pass the plug.

- **`Detector.warmup/2`** — generic helper invoking the optional `warmup/1`
  callback. Because `Detector` is host-implementable, a host detector may
  legitimately not implement `warmup`; this presence check is the sanctioned
  **host-boundary** exception to the no-duck-typing rule — the same one the
  existing `Cache.validate_options` optional callback uses
  ([cache.ex](../../../lib/image_pipe/cache.ex)) — not internal dispatch.
- **`Detector.ImageVision` warmup** triggers the YuNet load with one `detect/2`
  on a **modest, non-degenerate** synthetic image (e.g. ≥64×64, not 1×1 — some
  detectors error on degenerate input); `{:ok, []}` / no-face results count as
  success (the goal is the load). `ModelCache.fetch!` is the disk-only
  alternative; whether image_vision keeps an in-process session cache is an
  internal we don't assert — warmup is best-effort.
- **`Detector.Warmup` worker** — optional child spec the host adds to their tree:

  ```elixir
  {ImagePipe.Transform.Detector.Warmup,
   detector: ImagePipe.Transform.Detector.ImageVision, classes: ["face"], mode: :async}
  ```

  - A **`GenServer` with `restart: :transient`** (no detached Task, no
    `Task.Supervisor` — none exists in the tree, and `admission.ex` documents why
    this repo avoids per-config Task supervisors):
    - `:sync` — load in `init/1`, then `{:stop, :normal}`.
    - `:async` (**default**) — `init/1` returns `{:ok, state, {:continue, :warm}}`;
      the blocking load runs in `handle_continue` (off the host-boot path, since
      the supervisor's `start_link` returns once `init` returns), then
      `{:stop, :normal}`. The worker process *is* the supervised owner — nothing
      is orphaned.
  - **Needs no `trap_exit`.** A blocking `detect/2` in `handle_continue` cannot
    observe a supervisor shutdown until it returns; a shutdown mid-download is
    acceptable (download completes or is brutal-killed at the child_spec
    `shutdown` timeout — nothing is staged to clean up, unlike `SourceSession`).
  - **Retry is in-process, not supervisor-driven:** a failed warmup logs and does
    a bounded in-process retry, then terminates `:normal`. It must **not** raise —
    `restart: :transient` + a raised exit would restart-storm and, past
    `max_restarts`, take down the host's tree.
  - Dispatches via `Detector.warmup/2` with the detector as config data
    (boundary-safe). Pulls no new transform `deps:`.

- Consistency is the host's responsibility (same `detector` on plug and worker;
  no hidden global). Warming changes latency, not results; orthogonal to
  `detector_required`.

**Why host-wired (alternatives considered).** Only boot-time warming prevents
the first request from paying the cost, and `Application` boots before plug
mounts. Rejected: *app-env auto-start* (second config path; global singleton
doesn't compose with multiple mounts; drifts from the plug's detector).
Deferred: *automatic lazy warm* (`detector_warmup: :auto` plug option, idempotent
`:persistent_term`-guarded async warm at first-call — zero-wiring but never
guarantees warm-before-first-request); it layers cleanly on `warmup/2` later.

## Testing

- **Parser/planner:** `g:sm`→`:smart`; `g:sm`+config→`{:smart,:face_assist}`;
  `g:obj:face`→`{:detect,["face"]}`; **bare `g:obj`**, `g:obj:all`, multi-class,
  `objw`, `objects_position`/`obj_pos`/`op` all reject before side effects;
  `c:W:H:obj:face` parses (both crop paths); `extend:1:sm` /
  `extend_ar:1:obj:face` reject (locks the exclusion against new code);
  `g:obj:face:5:5` rejects (5 not a face class); order-insensitivity intact.
- **Producer (no dialect leak):** `PlanBuilder` emits only product-neutral guide
  terms — assert no `{:obj,_}`/`:sm` in the Plan. (Also justifies removing the
  two `:sm` rejections: the positive `g:sm → :smart` producer test is the
  behavior-change evidence.)
- **Deterministic ML via DI:** a fake `Detector` (a legit test double — it
  implements the public behaviour; **not** hand-built internal misuse) →
  - known boxes → `{:detect}` anchors on the area-weighted centroid;
  - known boxes + a fixture → `{:smart,:face_assist}` anchors on the blended
    point `P` (between attention and centroid), distinct from both pure
    attention and pure centroid;
  - out-of-image box → dropped → graceful attention, no crash;
  - `{:error,_}` → attention (graceful) / error (required);
  - **`detector: nil`** (both `{:detect}` and `{:smart,:face_assist}`) → graceful
    attention, no crash.
  Do **not** hand-build `CropGuided`/`region` literals outside
  parser/planner/adapter tests; route guide construction through the parser.
- **Attention behavior:** assert the attention-selected crop **region/offset
  differs from center** toward the salient area on a fixture — not exact-byte
  golden (robust to libvips upgrades).
- **Cache:** `:smart`, `{:smart,:face_assist}`, `{:detect,["face"]}` produce
  **three distinct** `guide_data/1` serializations (the key must even *build*);
  `{:smart,:face_assist}` dep-present (`identity` present) vs dep-absent
  (`{module, :unavailable}`) do **not** collide.
- **Strict-mode wire test:** `detector_required` + unavailable + `{:detect,_}` →
  error with **no source fetch AND no cache access** (assert neither
  `Source.resolve` nor `[:cache,:lookup]` fired); `{:smart,:face_assist}` never
  rejected.
- **Telemetry:** a `[:transform,:detect]` span fires with duration on a detect
  request; metadata carries boxes/labels/scores and **no** URL/key/path; the
  event is registered in `DefaultLogger`.
- **Warmup worker:** `start_supervised!` the `Warmup` child with a DI fake whose
  `warmup/1` **messages the test pid** (assert the call + `classes`, no sleep);
  for `:async` non-blocking, the fake blocks on a test signal and the test
  asserts `start_supervised!` returns before releasing it; assert termination
  `:normal` via `Process.monitor` + `assert_receive {:DOWN, …, :normal}`;
  unavailable detector → clean no-op that still terminates.
- **Real-dependency test:** tagged `@tag :image_vision`, **excluded by default**;
  run only in an opt-in lane that builds the lane-scoped dep (the lane must run
  `mix deps.get` with `IMAGE_VISION=1` set, since `mix.lock` won't track the dep
  otherwise) and prefetches YuNet via `ModelCache.fetch!`.
- **Wire-level Plug:** `g:sm` and `g:obj:face` end-to-end via `ImagePipe.call/2`
  — status, decoded output dimensions, gravity visibly shifting pixels vs a
  center-crop baseline.

**Test/dep hygiene:** no impossible-internal-misuse tests; no
existence/name-policing of `Detector`/`Warmup`; no `:sm`-still-rejected parity
pin after the feature lands; `image_vision` is env-gated (`IMAGE_VISION=1`
conditional dep + excluded tag) so plain `mix test`/`precommit` never builds the
Ortex/Rust/ONNX closure.

## Divergences (documented in the matrix)

1. **Model differences:** imgproxy object detection uses host-configured YOLO
   models with tunable confidence/NMS thresholds; ImagePipe's default adapter
   uses `image_vision` (YuNet for faces) with adapter-fixed thresholds. Detected
   boxes — and crops — differ. Compatible in semantics, not bit-identical.
2. **Gravity-mode math:** imgproxy's default obj gravity is
   `IMGPROXY_OBJECT_DETECTION_GRAVITY_MODE=max_score_area` (densest
   weighted-coverage window), not a centroid. ImagePipe approximates with an
   **area-weighted centroid**, so scattered multi-face layouts can differ.
   Faithful for the common single/clustered face case.
3. **`g:sm` blend:** imgproxy Pro's smart crop is configurable
   (`IMGPROXY_SMART_CROP_ADVANCED*`) and, with
   `IMGPROXY_SMART_CROP_FACE_DETECTION`, face-augmented globally — including the
   obj-no-detection `FALLBACK_TO_SMART_CROP`. ImagePipe maps `g:sm`→libvips
   attention, and `smart_crop_face_detection` blends attention⊕faces with our
   own weight `w` only on the `g:sm` guide; it does **not** propagate to the
   `{:detect,["face"]}` no-face fallback (plain attention). The blend is an
   approximation of imgproxy's unspecified internal combination.
4. **`co` alias:** imgproxy aliases `co` to both `contrast` and `crop_objects`;
   ImagePipe binds `co`→contrast only (`crop_objects` is out of scope). Noted on
   the `crop_objects` matrix row.

## Out of scope (follow-up issues)

- General `g:obj:%class…` for arbitrary `image_vision` labels (single + multi),
  `g:obj:all`, `g:objw` weighted gravity, `objects_position`/`op`.
- `IMGPROXY_OBJECT_DETECTION_GRAVITY_MODE`/`FALLBACK_TO_SMART_CROP`/
  `SMART_CROP_ADVANCED*` parity.
- Broader ML features reusing the same optional-dep seam (segmentation,
  background removal → ImageKit `e-bgremove`, classification, captioning).
- Automatic-lazy warmup (`detector_warmup: :auto`).

These are additive: they widen accepted `classes` and add adapter methods,
without changing the plan guide shape, the seam contract, or the cache discipline.

## Decisions log

- Approach A (extend the guide union + isolated `Detector` behaviour).
- Scope: face-aware subset first; general `g:obj` deferred but seam-ready.
- Absent-dep policy: configurable, default graceful; strict rejects `{:detect,_}`
  pre-fetch; `{:smart,:face_assist}` never hard-rejects.
- `IMGPROXY_SMART_CROP_FACE_DETECTION` modeled as a parser-config knob selecting
  a canonical plan guide, implemented as a **true attention⊕face blend** (the
  feature is meaningfully distinct from `g:obj:face` and faithful to imgproxy's
  "face step added to smart crop"; the smartcrop attention point is readable via
  `attention_x/attention_y`).
- Eager warmup host-wired (optional child spec + `warmup/2`), async by default.
- `classes` are strings (not atoms) to remove the `String.to_atom` hazard.
- `:smart` uses `Vix.Vips.Operation.smartcrop/3`.

## Review cycle

v3 incorporates **two** adversarial review cycles (five disjoint reviewers each:
architecture/boundaries, imgproxy fidelity, cache/telemetry/safety,
Elixir-OTP/testing, ML feasibility).

Cycle 1 fixes: cache-key `guide_data/1` would have raised; `Vix.Vips.Operation.smartcrop/3`
as the `:smart` call; identity/warmup feasibility (no image_vision version API;
`download_models` excludes YuNet); lane-scoped dep; `available?/1`/`identity/1`
arity; detector return validation + `nil`/bogus-box rungs; `[:transform,:detect]`
span; generic `Plan` accessor + arch tests; parser crop-path + bare-`g:obj`
rejection; matrix `gravity:obj`→⚠️; `classes` as strings.

Cycle 2 fixes (this revision): **corrected the false "smartcrop offset unreadable"
claim** and redesigned face-assist as a true attention⊕face blend (rather than a
faces-first variant redundant with `g:obj:face`); cache identity must be *read*
into `Key.build`/`plan_material`, not merely allowlisted (else availability never
keys → a different-bytes/same-key bug); `:detect` `classes` must be terminally
serialized (not recursed through `data/1`); register `[:transform,:detect]` in
`DefaultLogger`; make the `plug.ex` arch-test glob extension mandatory; define and
test the `nil`/unavailable detector path for face-assist; assert no-source-access
(not just no-cache) in the strict test; the adapter wraps `FaceDetection`'s bare
raising list with a narrow boundary `rescue`; §9 must replace the matrix wildcard
rows and annotate `crop_objects`/`co`.
