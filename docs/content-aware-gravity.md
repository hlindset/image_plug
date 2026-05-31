# Content-aware gravity (smart crop & face detection)

ImagePipe supports several content-aware ways to choose *where* a cover/crop is
anchored, on top of the usual fixed anchors and focal points:

| URL | What it does | Needs ML? |
| --- | --- | --- |
| `g:sm` | libvips **attention** smart crop — picks the most salient region | No |
| `g:obj:face` (and `c:W:H:obj:face`) | anchors the crop on **detected faces** | **Yes** |
| `g:obj` / `g:obj:all` | anchors on **all detected objects** (faces + COCO-80) | **Yes** |
| `g:obj:%c1:…:%cN` | anchors on specific object classes, e.g. `g:obj:car:dog` | **Yes** |
| `g:sm` + `smart_crop_face_detection` config | **blends** the attention point with detected faces | **Yes** |

`g:sm` works out of the box — it's pure libvips and needs no extra dependencies.
The face-aware and object-aware paths need an optional ML detector, which this
guide explains how to enable.

## Enabling face and object detection

Face and object detection are **off by default**. ImagePipe pulls no ML runtime
in a normal build; a host opts in by adding two dependencies:

```elixir
# mix.exs — in YOUR application's deps
{:image_vision, "~> 0.4"},
{:ortex, "~> 0.1"}
```

Both are required:

- **`image_vision`** provides `Image.FaceDetection` (YuNet) and
  `Image.Detection` (RT-DETR, COCO-80).
- **`ortex`** is the ONNX runtime `image_vision` runs models through.
  `image_vision` compiles the detection modules **only** when Ortex is present
  (`if ImageVision.ortex_configured?()`), so `image_vision` *without* `ortex`
  silently provides no detection. This is the single most common setup mistake.

Practical requirements:

- **A Rust toolchain** — `ortex` builds a native NIF (it needs `cargo`/`rustc`).
- **A one-time model download** — the YuNet face model (~340 KB) is fetched from
  HuggingFace on the **first** face detection request and cached on disk. The
  RT-DETR object model (~175 MB) must be pre-fetched explicitly (see
  [Warming up](#warming-up-avoiding-first-request-latency)); use
  `mix image_vision.download_models --detect` at build/deploy time to avoid
  first-request cold-start latency for object detection.
  The first cold face request therefore appears to "hang" while it downloads
  unless the warmup worker is used (see
  [Warming up](#warming-up-avoiding-first-request-latency)).

Once both deps compile, face and object detection **activates automatically** —
you don't have to configure anything. ImagePipe's default detector is a
`Composite` that routes `face` requests to the YuNet adapter
(`ImagePipe.Transform.Detector.ImageVision.Face`) and COCO-80 object requests to
the RT-DETR adapter (`ImagePipe.Transform.Detector.ImageVision.Objects`). Each
checks at runtime whether its `image_vision` module is loadable and uses it when
it is.

## What happens without it

ImagePipe never hard-fails just because the detector is missing. With no
`image_vision`/`ortex` (or when a request's image has no detectable face, or the
model errors), face-aware requests **fall back to `g:sm` libvips attention smart
crop** — a sensible result, just not face-aware. Your app keeps serving images.

If you would rather a face-*required* request fail loudly instead of silently
degrading, see [`detector_required`](#options) below.

## Options

Both options are passed to the plug at mount time (alongside `parser:`,
`sources:`, etc.):

```elixir
plug ImagePipe,
  parser: ImagePipe.Parser.Imgproxy,
  # ...
  detector: :default,        # default
  detector_required: false   # default
```

- **`detector`** — which detector backs the face- and object-aware paths.
  - `:default` *(default)* — the bundled `ImagePipe.Transform.Detector.Composite`,
    which routes faces to `ImageVision.Face` (YuNet) and objects to
    `ImageVision.Objects` (RT-DETR/COCO-80). Activates automatically when
    `image_vision` + `ortex` are loaded; reports unavailable (→ attention
    fallback) otherwise.
  - `nil` — detection disabled. Face-aware requests always fall back to attention.
  - a module implementing `ImagePipe.Transform.Detector` — a
    [custom detector](#custom-detectors).
- **`detector_required`** — boolean, default `false`.
  - `false` — **graceful**: a face-aware request with no available detector falls
    back to attention.
  - `true` — **strict**: a face-aware (`g:obj:face`) request is **rejected
    before any source fetch or cache access** when the detector is unavailable,
    returning a 422. (Availability is a cheap in-process check, so this decision
    is made up-front.) Note that `smart_crop_face_detection` (face-assisted
    `g:sm`) is *never* hard-rejected — it's an enhancement to an
    always-valid attention crop, so it always degrades to plain attention.

## Warming up (avoiding first-request latency)

Because the model downloads (and loads) on first use, the first cold face
request pays that cost. To pre-load it at boot, add the optional, host-wired
warmup worker to **your** supervision tree:

```elixir
# in your application.ex children
{ImagePipe.Transform.Detector.Warmup, detector: :default}
```

The default `classes: :all` warms both the face (YuNet) and object (RT-DETR)
models. If you only use face detection, you can pass `classes: ["face"]` to skip
the larger RT-DETR model. It runs once, off the boot path (it does not block your
supervisor's startup), triggers the model load, and then terminates normally (it
is `restart: :transient`, so it is not restarted). If the detector is unavailable
it is a clean no-op. The `:detector` option mirrors the plug's — pass the same
value you gave the plug (`:default`, a custom module, or `nil` to disable).

There is also a build/deploy-time option: `mix image_vision.download_models
--detect` pre-fetches the RT-DETR object model (~175 MB). The YuNet face model
(~340 KB) is downloaded on first use regardless; use the warmup worker (or just
accept the first-request download) for face detection.

## Custom detectors

The detector is a small, product-neutral behaviour, so you can swap in your own
(a different model, a remote service, a fake for tests):

```elixir
defmodule MyApp.MyDetector do
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def supported_classes(_opts), do: ["face", "car"]

  @impl true
  def detect(image, opts) do
    classes = Keyword.get(opts, :classes, :all)
    # ... return product-neutral regions for the requested classes ...
    {:ok, [%{label: "face", score: 0.97, box: {x, y, width, height}}]}
    # box is {x, y, width, height} in absolute top-left pixels
  end

  @impl true
  def available?(_opts), do: true

  @impl true
  def identity(_opts), do: {__MODULE__, "my-model-v1"}

  # optional
  @impl true
  def warmup(_opts), do: :ok
end
```

Then `detector: MyApp.MyDetector`. The `identity/1` return participates in the
cache key, so a model/version change you encode there correctly invalidates
cached results. Keep `identity/1` free of secrets — it appears in per-model
telemetry spans that fan out to all attached handlers. `supported_classes/1`
must be answerable even when the optional dep is absent; it is used for class
routing and availability checks before any model is loaded.

## General object gravity

Beyond face detection, ImagePipe supports the full `g:obj` object gravity
surface: specific COCO-80 classes, bare `obj` (all objects), and the `all`
pseudo-class.

**Class syntax.** Append one or more class names as colon-separated tokens:

```text
g:obj:car               # anchor on detected cars
g:obj:car:dog           # anchor on cars and dogs (class union)
g:obj                   # all detected objects — faces + all COCO-80 classes
g:obj:all               # explicit all-objects form, same as bare g:obj
c:W:H:obj:car           # crop form with specific class
```

Class names use the **underscore spelling** matching the COCO-80 vocabulary:
`traffic_light`, `sports_ball`, `hot_dog`, etc. The full 80-class list is in
`ImagePipe.Transform.Detector.ImageVision.Objects`.

**Union of detectors.** `g:obj` and `g:obj:all` route to *every* configured
child detector — both the face (YuNet) and object (RT-DETR) adapters run, and
their regions are merged before computing the crop focus. A class list routes
only to the detector(s) that own the requested classes; e.g. `g:obj:face` routes
only to YuNet, `g:obj:car` routes only to RT-DETR.

**Unknown classes degrade, never error.** If a requested class isn't claimed by
any configured detector, it is silently dropped. `g:obj:unicorn` produces the
same result as `g:obj` with no unicorn regions — the request succeeds and falls
back to attention saliency. Only classes that route to at least one child
contribute to the crop.

**Equal-weight area centroid.** The crop focus is the area-weighted centroid of
all detected regions, without per-class weights. With many mixed-size objects
the result naturally biases toward larger ones. If you want a face-centric crop
on a busy scene, use `g:obj:face` directly — or, in a future slice, use `objw`
per-class weights once that surface ships.

**Class-aware cache identity.** The cache key includes only the child detector
identities that the requested class set routes to. An object-only request
(`g:obj:car`) is unaffected by a face model version change, and vice versa.

**Model size and cold-start.** The RT-DETR model is approximately 175 MB. Unlike
the small YuNet face model, it is not downloaded on first use automatically — use
`mix image_vision.download_models --detect` at build/deploy time to pre-fetch
it, and add the warmup worker so it loads into memory before the first request
(see [Warming up](#warming-up-avoiding-first-request-latency)).

## How requests, the detector, and the cache interact

- `g:obj:face` and `g:obj:car:dog` (etc.) resolve the detected regions'
  **area-weighted centroid** to a focal point and reuse the normal focal-point
  crop. Multiple regions are combined by area; out-of-image or malformed boxes
  are dropped.
- The detector's **class-aware** `identity/1` is folded into the **cache key**
  for detection-aware requests. Only the child detectors that the requested class
  set routes to contribute to the key — so swapping the face model doesn't
  invalidate object-only cached results, and vice versa.
- When a detector runs, detection emits a `[:image_pipe, :transform, :detect]`
  telemetry span with honest duration (the model inference is real, eager work)
  — useful for spotting cold-start cost. Its `:result` metadata distinguishes a
  real detection (`:detected`), a normal no-object frame (`:no_regions`), and a
  configured detector that produced nothing usable (`:unavailable`, `:error`).
  The Composite also emits a nested `[:image_pipe, :transform, :detect, :model]`
  span per child detector that ran — see [telemetry.md](telemetry.md) for the
  full schema.
  When no detector is configured, nothing runs, so instead of a span ImagePipe
  emits a one-shot `[:image_pipe, :transform, :detect, :skipped]` marker
  (`result: :no_detector`). The opt-in default Logger escalates `:unavailable`,
  `:error`, and `:no_detector` to `:warning`. ImagePipe emits no request-time
  `Logger` calls itself — fallback observability is telemetry-only. See
  [telemetry.md](telemetry.md).

## imgproxy compatibility & divergences

`g:obj:face` / `c:W:H:obj:face` and multi-class `g:obj:%c1:…:%cN` / `g:obj` /
`g:obj:all` are now supported. The remaining out-of-scope parts of imgproxy's
object gravity surface are `objw` (per-class detection weights) and
`objects_position` — these are deferred to a future slice. ImagePipe uses
`image_vision`'s YuNet face model (not imgproxy's configurable YOLO models) and
RT-DETR for COCO-80 objects (not YOLO), so detected boxes — and the resulting
crops — are compatible in intent but not bit-identical to imgproxy. The
face-assist blend weight is ImagePipe's own approximation. The full row-by-row
mapping and divergence notes are in
[imgproxy_support_matrix.md](imgproxy_support_matrix.md#smart-crop-object-detection-classification-and-best-format-models).
