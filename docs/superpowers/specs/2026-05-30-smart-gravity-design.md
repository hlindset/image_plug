# Smart gravity & the ML detection seam — design

Status: proposed
Date: 2026-05-30
Issue: [#34 Add smart gravity and object-aware crop anchors](https://github.com/hlindset/image_plug/issues/34)

## Summary

Add content-aware crop anchoring to ImagePipe, closing the last gap in the
imgproxy cover/crop story. The increment delivers three user-visible
capabilities, all built on one product-neutral detector seam:

1. **`g:sm` → libvips attention smart crop** — deterministic, no dependency.
2. **`g:obj:face` → face-aware gravity** — anchors the crop on detected faces
   via the optional `image_vision` dependency, falling back to attention.
3. **`smart_crop_face_detection` config → face-assisted `g:sm`** — biases the
   attention crop toward faces when configured (imgproxy Pro
   `IMGPROXY_SMART_CROP_FACE_DETECTION`).

Face detection is the **first member** of a general object-detection seam.
General object classes, multi-class, weighted (`objw`), and `objects_position`
are deliberately deferred (see [Out of scope](#out-of-scope)), but the seam and
the product-neutral plan representation are designed so they are additive.

## Goals

- Faithful imgproxy compatibility for `g:sm` and `g:obj:face`.
- A product-neutral, host-implementable `Detector` behaviour that is the
  foundation for the broader ML compatibility program (general object gravity,
  and later segmentation/background-removal/etc. as separate features).
- Optional ML dependency: default builds pull no ONNX/ML runtime; hosts opt in.
- Deterministic, model-free unit tests via a dependency-injected detector.
- Cache correctness when detection influences output bytes.

## Non-goals

- Bit-identical parity with imgproxy's ML output (different models → different
  boxes; see [Divergences](#divergences)).
- General object-class gravity, weights, and object positioning (deferred).

## Background & constraints

Relevant current code:

- `ImagePipe.Plan.Operation.CropGuided` ([crop_guided.ex](../../../lib/image_pipe/plan/operation/crop_guided.ex)) —
  `guide` union: `anchor() | {:anchor, h, v} | {:focal, {:ratio,..}, {:ratio,..}}`.
  `@enforce_keys [:width, :height, :guide]`.
- `ImagePipe.Plan.Operation.Resize` (cover) carries the same `guide`; both the
  cover path and the explicit-crop path translate it through
  `tagged_executable_gravity/1` in
  `ImagePipe.Transform.PlanExecutor` ([plan_executor.ex](../../../lib/image_pipe/transform/plan_executor.ex)).
  **Consequence:** a new guide variant is honored by both cover-resize and
  `c:` crop with no extra wiring.
- `ImagePipe.Transform.Operation.Crop` ([crop.ex](../../../lib/image_pipe/transform/operation/crop.ex)) —
  resolves transform-level gravity `{:anchor, h, v}` / `{:fp, x, y}` to crop
  origin; calls `Image.crop/5`.
- `ImagePipe.Transform.State` ([state.ex](../../../lib/image_pipe/transform/state.ex)) —
  carries only `image` + `debug`. The `execute/2` operation callback receives
  no runtime options.
- `ImagePipe.Parser.Imgproxy.PlanBuilder` ([plan_builder.ex:196](../../../lib/image_pipe/parser/imgproxy/plan_builder.ex)) —
  currently **rejects** `g:sm` with `{:unsupported_gravity, :sm}`.
- `ImagePipe.Parser.Imgproxy.OptionGrammar` ([option_grammar.ex](../../../lib/image_pipe/parser/imgproxy/option_grammar.ex)) —
  parses gravity values; `sm` already parses to `gravity: :sm`. Object gravity
  (`obj:...`) is not yet parsed.
- `ImagePipe.Transform` ([transform.ex](../../../lib/image_pipe/transform.ex)) —
  `use Boundary` with explicit `exports:` and `deps: [Plan, Telemetry]`.

Architecture rules that shape this design (from `CLAUDE.md`):

- The native plan is product-neutral; imgproxy `sm`/`obj` must translate into
  `ImagePipe.Plan` and never leak past the parser.
- The `Detector` is a host-implementable behaviour, validated as a runtime
  boundary; its returns are validated, but trusted internal callbacks are not
  duck-typed.
- Request/source/response dispatch through generic `ImagePipe.Transform`; they
  may read product-neutral `Plan` fields but must not name concrete transform
  modules.
- Cache key includes inputs that change successful encoded bytes; not safety
  limits. Greenfield → reshape key data in place, no version bump.

## Design

### 1. Product-neutral plan representation

Extend the shared `guide` union (`CropGuided` and `Resize`) with:

- `:smart` — saliency/attention strategy (maps to libvips attention).
- `{:smart, :face_assist}` — attention biased by detected faces.
- `{:detect, classes}` — anchor on detected objects of `classes`. `classes` is
  a **closed, validated set**; this increment accepts only `[:face]`. The atom
  `:face` comes from a fixed parser mapping of the literal `face` token —
  **never `String.to_atom/1` on user input**.

Rationale for two smart variants: imgproxy semantics differ. `g:obj:face`
(`{:detect,[:face]}`) is *faces-first* — the crop is anchored on faces, with
attention only as a no-detection fallback. Face-assisted `g:sm`
(`{:smart,:face_assist}`) is *attention-first* — faces nudge an
otherwise-attention crop.

`@type guide` gains these three forms. No new operation struct is introduced
(Approach A); geometry stays in one place.

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
  @callback available?() :: boolean()

  @doc "Stable identity for cache-key material: {module, version}."
  @callback identity() :: {module(), term()}

  @doc "Optionally pre-load models so the first request doesn't pay download cost."
  @callback warmup(opts :: keyword()) :: :ok | {:error, term()}
  @optional_callbacks warmup: 1
end
```

- `region` shape mirrors `image_vision` (`%{label, score, box: {x,y,w,h}}`), so
  general object detection is additive — only the accepted `classes` widen.
- `available?/0` powers the strict-mode pre-fetch check and graceful fallback.
- `identity/0` supplies cache-key material (resolves self-review gap #1).

**Default adapter** `ImagePipe.Transform.Detector.ImageVision`:

- Wraps `Image.FaceDetection.detect/1` for `:face`. **This is required, not a
  preference:** `image_vision`'s general object detector
  (`Image.Detection`, default `onnx-community/rtdetr_r50vd`) uses COCO classes
  (`person`, `car`, …) and has **no `face` class**. Faces come from a separate
  module backed by OpenCV YuNet (~340 KB), downloaded independently of the ONNX
  default-models set. General classes (`Image.Detection`, ~175 MB RT-DETR) are
  the additive path for future `g:obj:%class…` — same `region` return shape.
- Guarded by `Code.ensure_loaded?(Image.FaceDetection)` in `available?/0`,
  `@compile {:no_warn_undefined, ...}`, and a `.dialyzer_ignore.exs` entry, so
  it compiles cleanly when the dep is absent.
- `identity/0` returns `{__MODULE__, <model-id+version>}` (e.g. the YuNet model
  identifier), so cache keys distinguish models. Returns an `:unavailable`
  marker when the dep is absent (face-assist output then differs from
  dep-present, and the key must reflect that).
- `warmup/1` triggers the configured classes' model load (for `:face`, one
  detection that populates `image_vision`'s on-disk cache + `:persistent_term`);
  no-op `{:error, :unavailable}` when the dep is absent. See
  [§10](#10-eager-model-warmup-optional).

**Optional dependency policy:** `image_vision` is **not** a declared dependency
of ImagePipe (hosts add it), so default builds pull no ONNX runtime. To make the
real-dependency tests executable in CI, `image_vision` is added as a
**`:test`-only** dependency (resolves self-review gap #3).

### 3. Configuration

Two distinct config surfaces, validated explicitly (NimbleOptions /
adapter-owned `validate_options!/1`, per existing patterns in
`ImagePipe.Plug`):

- **Transform-runtime (product-neutral)** — top-level plug options:
  - `detector` — a module implementing `ImagePipe.Transform.Detector`, or `nil`
    (default `ImagePipe.Transform.Detector.ImageVision`, which simply reports
    `available?() == false` when the dep is absent).
  - `detector_required` — boolean, default `false`. `false` → graceful
    attention fallback when unavailable; `true` → reject before side effects.
- **imgproxy-parser dialect knob** — under `imgproxy:`:
  - `smart_crop_face_detection` — boolean, default `false`. When `true`, the
    parser translates `g:sm` to `{:smart, :face_assist}` instead of `:smart`.
    Mirrors `IMGPROXY_SMART_CROP_FACE_DETECTION`.

This keeps the *detector* product-neutral and the *imgproxy face-assist toggle*
isolated in the parser/dialect layer.

### 4. Parser mapping (imgproxy)

`OptionGrammar`: add object-gravity value parsing —
`g:obj:%class[:%class...]`. Produces a parser-internal gravity value such as
`{:obj, [classes]}`. `objw:` and `objects_position`/`op` parse to recognized
but unsupported values (so they reject loudly, not silently ignore).

`PlanBuilder`: replace the `:sm` rejection
([plan_builder.ex:196](../../../lib/image_pipe/parser/imgproxy/plan_builder.ex)) with:

- `gravity: :sm` → guide `:smart`, or `{:smart, :face_assist}` when
  `smart_crop_face_detection` is configured.
- `gravity: {:obj, ["face"]}` (single `face` class) → guide `{:detect, [:face]}`.
- `gravity: {:obj, <other/multi/all>}`, `{:objw, ...}`, any `objects_position`
  → `{:error, {:unsupported_gravity, ...}}` (documented, fails before fetch).
- `extend` / `extend_ar` continue to reject `sm`/`obj`/`objw` (imgproxy does too).

### 5. Execution & fallback

`Transform.State` gains a `detector` field (`nil | module`) and a
`detector_required` boolean. `PlanExecutor.execute/3` reads these from its
`opts` and populates `State` before running operations — keeping the
`execute(operation, state)` callback signature stable (resolves gap #7).

`tagged_executable_gravity/1` maps the new plan guides to transform-level
gravity intents: `:smart`, `{:smart, :face_assist}`, `{:detect, classes}`.

`Crop.execute/2` resolution:

- `:smart` → libvips attention smart crop selects the window on the
  (cover-resized) image. Exact call (`Image.thumbnail crop: :attention` vs a
  lower-level `smartcrop` on the already-resized image) is settled in
  implementation, since resize is currently a separate step.
- `{:detect, [:face]}` → call `state.detector.detect(image, classes: [:face])`:
  - `{:ok, [_|_] = faces}` → focus point = **area-weighted centroid** of face
    boxes → resolve as `{:fp, x, y}` and reuse the existing focal-point crop
    geometry. (We *anchor* a target-size window on the faces; we do **not**
    zoom-to-face — this matches imgproxy `obj` gravity and deliberately
    diverges from the reference project's `crop_largest`. Resolves gap #5.)
  - `{:ok, []}` (no detection) → fall back to `:smart` (attention).
  - `{:error, _}` (runtime failure: model load/timeout) → graceful fallback to
    `:smart`; or, when `detector_required`, surface the error. (Resolves gap #2:
    a detector runtime error is a distinct rung from "no face found".)
- `{:smart, :face_assist}` → run attention; if faces are found, shift the
  attention-selected window toward the face centroid (bounded to the image);
  else pure attention. The exact blend is **our approximation** of imgproxy's
  internal combination and is documented as a divergence.

**Strict-mode pre-fetch check:** when `detector_required: true` and the
validated plan contains a `{:detect, _}` guide and `detector.available?()` is
`false`, the request is rejected **before source fetch or cache access**. This
check lives in the request/plug layer and queries the product-neutral `Plan`
for a detect guide (a `Plan.*` field, not a transform module — boundary-safe).
Availability is `Code.ensure_loaded?`, known without fetching.

`{:smart, :face_assist}` is **never** hard-rejected: it is an enhancement to an
already-valid attention crop, so it always degrades to plain attention when the
detector is unavailable, regardless of `detector_required`.

Note `available?/0` means *the dependency is loaded* — not that model weights
are on disk. The first detection downloads weights (see
[Operational notes](#9-operational-notes-model-distribution--latency)); strict
mode guarantees the capability exists, not that the first call is fast.

### 6. Cache key

When the canonical plan carries a `{:detect, _}` or `{:smart, :face_assist}`
guide, include the configured detector's `identity/0` (`{module, version}`) in
cache-key material — a model swap changes output bytes. Plain `:smart`
(attention) adds nothing: it is deterministic and already canonical as a plan
field (libvips-version concerns remain with
[#43](https://github.com/hlindset/image_plug/issues/43)). The requested
`classes` are already in the key via the canonical plan guide. Greenfield:
reshape key data in place; no version bump.

### 7. Boundary & namespaces

- `ImagePipe.Transform.Detector` (behaviour),
  `ImagePipe.Transform.Detector.ImageVision` (default adapter), and
  `ImagePipe.Transform.Detector.Warmup` (optional worker, [§10](#10-eager-model-warmup-optional))
  live in the transform boundary; add `Detector` and `Detector.Warmup` to
  `Transform`'s `exports:`
  ([transform.ex:14](../../../lib/image_pipe/transform.ex)). Transform `deps:`
  are unchanged (the adapter references external `Image.*`, not an internal
  boundary).
- The detector module reaches execution as **config data** threaded
  request → `execute_plan/3` opts → `State`; the request never names the
  concrete adapter (boundary rule preserved).
- An architecture test asserts request/source/response code does not reference
  concrete detector modules and that `obj`/`sm` do not leak past the parser.

### 8. Demo & docs

- `demo/` imgproxy controls + URL state gain `sm` and `obj:face` gravity
  options (project rule: demo updated in the same change).
- `docs/imgproxy_support_matrix.md`: `g:sm` ✅, `g:obj:face` ✅,
  `IMGPROXY_SMART_CROP_FACE_DETECTION` ✅ (config), with explicit
  [Divergences](#divergences). Remaining `obj`/`objw`/`objects_position` stay ⭕
  with a note pointing at the seam.

### 9. Operational notes: model distribution & latency

`image_vision` downloads model weights on first call and caches them on disk,
so a cold detection request appears to "hang" during the download. Implications:

- **Readiness vs availability.** `available?/0` is a cheap `Code.ensure_loaded?`
  check (used by the strict pre-fetch gate). It does **not** guarantee weights
  are present. Warmup/readiness is an operational concern, not a request-time
  guarantee; ImagePipe does not block boot on a download.
- **Cost is bounded to cache misses.** Detection runs only when producing a
  response (cache miss); successful encoded responses are served from cache
  without re-running the model.
- **Face-first keeps this cheap.** Face detection uses YuNet (~340 KB), so the
  per-request and CI cost is small. General object gravity (deferred) would pull
  RT-DETR (~175 MB), and captioning/zero-shot/segmentation models are far larger
  (605 MB–990 MB) — another reason to land face first and defer the rest.
- **Two complementary warmups:** `mix image_vision.download_models` puts weights
  on disk at build/deploy time; the optional `Detector.Warmup` worker
  ([§10](#10-eager-model-warmup-optional)) triggers the in-process load at boot.
  Together they remove first-request latency. The `:test`-dep CI lane
  pre-downloads the YuNet face model before the real-dep test.
- Bounding per-request ML time is host/runtime territory and aligns with the
  processing-timeout work in
  [#49](https://github.com/hlindset/image_plug/issues/49); not in this scope.

### 10. Eager model warmup (optional)

Warmup is **host-owned and opt-in**, to avoid a second runtime config path:
ImagePipe's detector config travels through plug init options, but
`ImagePipe.Application` boots before any plug mounts and cannot see them. So
ImagePipe ships the *capability*; the host wires it into **their** supervision
tree with the same detector config they pass the plug.

- **`ImagePipe.Transform.Detector.warmup/2`** — generic helper:
  `warmup(detector_module, opts)` invokes the optional `warmup/1` callback if
  the detector implements it, else a no-op `:ok`. Hosts may call this directly
  (a `Task` in their `Application.start/2`, a release task, etc.).
- **`ImagePipe.Transform.Detector.Warmup`** — optional supervised child spec the
  host adds to their tree:

  ```elixir
  {ImagePipe.Transform.Detector.Warmup,
   detector: ImagePipe.Transform.Detector.ImageVision,
   classes: [:face],
   mode: :async}
  ```

  - `mode: :async` (**default**) — warmup runs off the init path (supervised
    `Task`) so it never blocks the host's boot or its other children.
  - `mode: :sync` — warmup runs during the worker's init (host places it where
    blocking is acceptable).
  - **transient** restart: it does its one-shot load and terminates `:normal`;
    it is not restarted on success. Failures are logged (and retried per a
    bounded policy in `:async` mode); a missing dep makes warmup a clean no-op.
  - Dispatches through `Detector.warmup/2` with the detector passed as **config
    data** — boundary-safe, no concrete-module reference in request code.

- **Consistency is the host's responsibility:** the host passes the same
  `detector` to both the plug and the `Warmup` child. ImagePipe does not link
  them through a global (that would reintroduce the second config path).
- Warming makes the first real request fast; it does not change results. It is
  orthogonal to the `detector_required` gate (which concerns *capability*, not
  readiness).

**Why host-wired (alternatives considered).** Only warming *at boot* prevents
the first request from paying the download cost, and `ImagePipe.Application`
boots before any plug mounts — so a boot-time warm needs either app-env config
or the host's own tree. Host-wiring keeps detector config on the single
plug-init path and composes with multiple mounts. Rejected/deferred:

- *Auto-start from app-env* — least wiring, but a second config path parallel
  to plug init opts, a global singleton that does not compose with multiple
  mounts using different detectors, and prone to drifting from the plug's
  detector. Not pursued.
- *Automatic lazy warm (`detector_warmup: :auto` plug option)* — an idempotent,
  `:persistent_term`-guarded async warm triggered at first-call, reusing the
  plug's own detector config (no second config path; precedent:
  `Image.Plug.Capabilities` probing AVIF once). Clean and zero-wiring, but it
  does not guarantee warm-before-first-request (request #1 still races) and adds
  the idempotency machinery. **Deferred as a future enhancement** if explicit
  wiring proves annoying; it layers cleanly on top of the `warmup/2` helper.

## Testing

- **Parser/planner:** `g:sm`→`:smart`; `g:sm`+config→`{:smart,:face_assist}`;
  `g:obj:face`→`{:detect,[:face]}`; `obj` multi/all/`objw`/`objects_position`
  rejected; order-insensitivity intact.
- **Deterministic ML via DI:** a fake `Detector` returning known boxes →
  assert the focal crop anchors on the area-weighted centroid. No model/network.
- **Attention behavior:** assert the attention-selected crop **region/offset
  differs from center** toward the salient area on a fixture — not exact-byte
  golden (robust to libvips upgrades; resolves gap #4).
- **Real-dependency test:** gated on `Code.ensure_loaded?(Image.FaceDetection)`,
  exercised in the `:test`-dep CI lane.
- **Fallback wire tests:** dep-absent + graceful → attention output;
  dep-absent + `detector_required` → error with **no source/cache access**;
  detector `{:error,_}` → graceful attention (and error when required).
- **Cache:** `{:detect,…}` vs `:smart` guides do not collide; detector
  `identity/0` participates in the key; two identities → distinct keys.
- **Wire-level Plug:** `g:sm` and `g:obj:face` end-to-end via real
  `ImagePipe.call/2` — status, decoded output dimensions, and gravity visibly
  shifting pixels vs a center-crop baseline.
- **Warmup worker:** with a DI fake detector implementing `warmup/1`,
  `start_supervised!` the `Warmup` child and assert it invokes `warmup/1` with
  the configured `classes` and terminates `:normal` (via `Process.monitor` +
  `assert_receive {:DOWN, ...}`, no `sleep`); `:async` mode does not block; an
  unavailable detector makes warmup a clean no-op that still terminates.

## Divergences (documented in the matrix)

1. **Model differences:** imgproxy object detection uses host-configured YOLO
   models; ImagePipe's default adapter uses `image_vision` (YuNet for faces).
   Detected boxes — and therefore crops — differ. Compatible in semantics, not
   bit-identical.
2. **`g:sm` is pure attention by default:** imgproxy Pro can face-augment smart
   crop via `IMGPROXY_SMART_CROP_FACE_DETECTION`; ImagePipe reproduces this only
   when `smart_crop_face_detection` is configured, and the attention⊕face
   combination is our own reasonable approximation.

## Out of scope (follow-up issues)

- General `g:obj:%class…` for arbitrary `image_vision` labels (single + multi).
- `g:obj:all` pseudo-class and `g:objw` weighted gravity.
- `objects_position` / `op` object placement.
- Broader ML features reusing the same optional-dep seam pattern (segmentation,
  background removal → ImageKit `e-bgremove`, classification, captioning).

These are additive: they widen the accepted `classes` set and add adapter
methods, without changing the plan guide shape, the seam contract, or the cache
discipline established here.

## Decisions log

- Approach A (extend the guide union + isolated `Detector` behaviour) over a
  separate precrop stage (B) or a dedicated `SmartCrop` op (C): least surface,
  reuses focal geometry, one product-neutral seam.
- Scope: face-aware subset first; general `g:obj` deferred but seam-ready.
- Absent-dep policy: configurable, default graceful (attention fallback).
- `IMGPROXY_SMART_CROP_FACE_DETECTION` included, modeled as a parser-config
  knob that selects a canonical plan guide (cache-correct, not hidden runtime
  behavior).
- Eager model warmup is host-owned (optional `Detector.Warmup` child spec +
  `warmup/2` helper + optional behaviour callback), opt-in and async by
  default, rather than auto-started from app-env — which would split detector
  config across two runtime paths.
