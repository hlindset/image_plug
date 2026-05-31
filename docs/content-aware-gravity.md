# Content-aware gravity (smart crop & face detection)

ImagePipe supports three content-aware ways to choose *where* a cover/crop is
anchored, on top of the usual fixed anchors and focal points:

| URL | What it does | Needs ML? |
| --- | --- | --- |
| `g:sm` | libvips **attention** smart crop — picks the most salient region | No |
| `g:obj:face` (and `c:W:H:obj:face`) | anchors the crop on **detected faces** | **Yes** |
| `g:sm` + `smart_crop_face_detection` config | **blends** the attention point with detected faces | **Yes** |

`g:sm` works out of the box — it's pure libvips and needs no extra dependencies.
The face-aware paths need an optional ML detector, which this guide explains how
to enable.

## Enabling face detection

Face detection is **off by default**. ImagePipe pulls no ML runtime in a normal
build; a host opts in by adding two dependencies:

```elixir
# mix.exs — in YOUR application's deps
{:image_vision, "~> 0.4"},
{:ortex, "~> 0.1"}
```

Both are required:

- **`image_vision`** provides `Image.FaceDetection` (the YuNet face model).
- **`ortex`** is the ONNX runtime `image_vision` runs the model through.
  `image_vision` compiles `Image.FaceDetection` **only** when Ortex is present
  (`if ImageVision.ortex_configured?()`), so `image_vision` *without* `ortex`
  silently provides no face detection. This is the single most common setup
  mistake.

Practical requirements:

- **A Rust toolchain** — `ortex` builds a native NIF (it needs `cargo`/`rustc`).
- **A one-time model download** — the YuNet model (~340 KB) is fetched from
  HuggingFace on the **first** detection request and cached on disk. The first
  cold request therefore appears to "hang" while it downloads (see
  [Warming up](#warming-up-avoiding-first-request-latency)).

Once both deps compile, face detection **activates automatically** — you don't
have to configure anything. ImagePipe's default detector
(`ImagePipe.Transform.Detector.ImageVision`) checks at runtime whether
`Image.FaceDetection` is loadable and uses it when it is.

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

- **`detector`** — which detector backs the face-aware paths.
  - `:default` *(default)* — the bundled `ImagePipe.Transform.Detector.ImageVision`
    adapter. Activates automatically when `image_vision` + `ortex` are loaded;
    reports unavailable (→ attention fallback) otherwise.
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
{ImagePipe.Transform.Detector.Warmup,
 detector: ImagePipe.Transform.Detector.ImageVision,
 classes: ["face"]}
```

It runs once, off the boot path (it does not block your supervisor's startup),
triggers the model load, and then terminates normally (it is `restart:
:transient`, so it is not restarted). If the detector is unavailable it is a
clean no-op. Pass the **concrete** detector module here (not `:default`).

There is also a build/deploy-time option: `mix image_vision.download_models`
pre-fetches some models — but note it does **not** include the YuNet face model;
use the warmup worker (or just accept the first-request download) for faces.

## Custom detectors

The detector is a small, product-neutral behaviour, so you can swap in your own
(a different model, a remote service, a fake for tests):

```elixir
defmodule MyApp.MyDetector do
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def detect(image, opts) do
    classes = Keyword.get(opts, :classes, [])
    # ... return product-neutral regions ...
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
cached results.

## How requests, the detector, and the cache interact

- `g:obj:face` resolves the detected faces' **area-weighted centroid** to a focal
  point and reuses the normal focal-point crop. Multiple faces are combined by
  area; out-of-image or malformed boxes are dropped.
- The detector's `identity/1` is folded into the **cache key** for face-aware
  requests, so swapping the detector/model (or running with vs. without the dep)
  never serves stale bytes.
- Detection emits a `[:image_pipe, :transform, :detect]` telemetry span with
  honest duration (the model inference is real, eager work) — useful for
  spotting cold-start cost. Its `:result` metadata distinguishes a real
  detection (`:detected`), a normal no-face frame (`:no_regions`), and an
  unfulfillable face-aware request that fell back to attention (`:unavailable`,
  `:error`, `:no_detector`). The opt-in default Logger escalates those last
  three to `:warning`. ImagePipe emits no request-time `Logger` calls itself —
  fallback observability is telemetry-only. See [telemetry.md](telemetry.md).

## imgproxy compatibility & divergences

`g:obj:face` / `c:W:H:obj:face` are a faithful single-class (`face`) subset of
imgproxy's object gravity; the broader object-detection surface (general classes,
`objw`, `objects_position`) is out of scope. ImagePipe uses `image_vision`'s
YuNet face model rather than imgproxy's configurable YOLO models, so detected
boxes — and the resulting crops — are compatible in intent but not bit-identical.
The face-assist blend weight is ImagePipe's own approximation. The full row-by-row
mapping and divergence notes are in
[imgproxy_support_matrix.md](imgproxy_support_matrix.md#smart-crop-object-detection-classification-and-best-format-models).
