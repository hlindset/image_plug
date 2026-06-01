# Shrink-on-load for large downscales — design

Status: draft (v2 — revised after a 3-way parallel review: Vix/libvips correctness, architecture/boundaries, tests/safety/measurement; see [Review cycle](#review-cycle))
Date: 2026-06-01
Issue: [#28 Add shrink-on-load optimization for large downscales](https://github.com/hlindset/image_plug/issues/28)
Plan: TBD

## Summary

Large originals that are immediately downscaled cost memory and CPU
proportional to their **full decoded resolution**, even when the output is
tiny. An 8000×6000 RGB image is ~144 MB decoded, regardless of the requested
800×600 output. This increment makes ImagePipe decode such requests at a
reduced resolution using libvips **shrink-on-load**, so the full-resolution
bitmap is never materialized.

The enabling change is to stop feeding decode through a non-seekable stream and
instead always hand libvips a **seekable source** (a file path, or an in-memory
buffer of the compressed bytes). Only seekable sources let us cheaply read the
header, compute a shrink factor, and re-open the image with that factor. The
current `Image.open(stream)` path uses Vix's `new_from_enum`, which is backed by
a non-seekable OS pipe: it is **read-once**, so the header cannot be inspected
and the source re-opened with a computed shrink, and for random-access
transforms libvips falls back to materializing the entire decoded image.

The decode-input model is unified: **one seekable-source decode path** for all
sources. Decode planning is extended from "choose sequential vs random access"
to "compute `{access, load_option}` for a seekable open", where `load_option` is
a per-format load shrink. Downstream geometry (residual resize, crop, gravity)
is adjusted for the prescale, mirroring imgproxy's `scale_on_load` step.

Concurrent download-and-decode via a seekable async source (imgproxy v4's
"parallel image downloading") is **out of scope** and tracked as a separate,
forward-compatible follow-up
([#139](https://github.com/hlindset/image_pipe/issues/139)) — it is a
latency/throughput feature, not a memory feature, and requires extending the Vix
NIF layer.

## Goals

- Large downscale requests decode at reduced resolution where the source
  format and runtime support it, cutting peak memory and CPU.
- One decode-input path for all sources (file, HTTP, cache bytes), built on
  seekable libvips sources rather than the read-once stream path.
- Preserve every existing request-safety boundary, and **fix** the input-pixel
  limit so it cannot be bypassed by shrink-on-load.
- A deterministic test proving the full-resolution bitmap is never
  materialized, plus a reported (non-gating) memory/CPU benchmark.
- Documented format gating and the output-equivalence contract.

## Non-goals

- Bit-identical output versus the full-decode-then-resize path. Shrink-on-load
  plus a residual high-quality resize is, by construction, not pixel-identical.
  The contract becomes dimension-exact + bounded perceptual similarity (see
  [Output equivalence contract](#output-equivalence-contract)).
- Concurrent download-and-decode / seekable async source (deferred; see
  [Out of scope](#out-of-scope)).
- Lowering the bound on compressed-body memory for HTTP. The body is still held
  up to `max_body_bytes`; the win is on the decode side.
- Shrink-on-load for formats the `image`/Vix open API cannot shrink on load
  (PNG, HEIF/AVIF, and others); those fall back to a full-resolution decode plus
  residual resize.

## Background: why the current path is the wrong one

Vix exposes three ways to load a formatted image, and they are not equivalent:

| Loader | `Image.open/2` dispatch | Backed by | Random access | Header-then-reopen with shrink |
|---|---|---|---|---|
| `new_from_enum/2` | stream / enumerable | `Vix.SourcePipe` → `vips_source_new_from_descriptor(pipe_fd)` | no (read-once) | no — read-once, cannot inspect header then re-open; random-access transforms force full materialization |
| `new_from_buffer/2` | binary | `vips_image_new_from_buffer` (bytes in memory) | yes | yes |
| `new_from_file/2` | path string | mmap'd file | yes | yes |

`vips_source_new_from_descriptor(fds[0])` (`deps/vix/c_src/pipe.c`) wraps the
read end of an OS `pipe()`. A pipe fd is non-seekable (`lseek` → `ESPIPE`), so
libvips treats it as a sequential pipe. (Note: the pipe loader *does* accept a
`shrink:`/`scale:` option and JPEG shrink-on-load is itself sequential, so the
problem is not that shrink is rejected — it is that the source is read-once, so
the two-pass "read header dims → re-open with a computed shrink" flow this design
relies on is impossible, and random-access transforms still materialize the full
decode.)

ImagePipe currently routes **all** decode through `Image.open(stream)` →
`new_from_enum`, including the filesystem source, which deliberately converts a
seekable file into a non-seekable byte stream via `File.stream!/3`
(`lib/image_pipe/source/file.ex`). So today:

- Header-driven shrink-on-load is impossible (cannot re-open a consumed pipe).
- For the random-access majority (crop, cover, rotate, canvas, padding — see
  `lib/image_pipe/transform/decode_planner.ex`), libvips already materializes
  the full decoded image; the stream provides no memory benefit there.

The decode planner added in PR #42 (sequential vs random access selection) is a
real but minor optimization of the *access pattern*; it does not reduce the
decoded-pixel buffer, which is the dominant cost for large downscales.

## Architecture

### One seekable-source decode path

Replace `Image.open(stream)` for decode with a seekable open chosen by source
kind:

- **File source:** stop using `File.stream!/3`; resolve to the on-disk path and
  open it with `Image.open(path, opts)` (`new_from_file` — mmap, random access,
  shrink/scale). The decode-time path must still pass through the source's
  existing `safe_path/2` + `regular_file/1` validation (`source/file.ex`); the
  path-based open must not bypass the traversal/regular-file checks the stream
  fetch performs today.
- **HTTP and cache-bytes sources:** keep the guarded `WrappedStream`
  (`lib/image_pipe/source.ex`, `WrappedStream`) as the **fetch/safety** layer —
  it counts bytes and cancels the origin response once `max_body_bytes` is
  exceeded — but **drain it into a bounded in-memory binary** rather than
  feeding it to the decoder. The drain **fails closed**: if the body limit is
  exceeded or a transport/stream error occurs, the drain returns
  `{:error, {:source, …}}` **before** `Image.open` is ever called, preserving
  the current error tags (`:body_too_large`, transport reasons). Then
  `Image.open(binary, opts)` (`new_from_buffer` — random access, shrink/scale).

`new_from_enum`/`SourcePipe` is no longer used for decode. The guarded stream
survives only as the bounded byte producer that fills the buffer; the existing
mid-stream cancel on oversized bodies is preserved, so the maximum compressed
data ever held is `max_body_bytes`.

This unification removes the source-kind branch at the decode boundary: the
downstream pipeline always receives a seekable libvips image. The only branch
is *how the seekable source is produced* (path vs. drained buffer), localized to
the source layer.

#### `Source.Response` contract change (Source boundary)

`%Source.Response{stream: Enumerable.t()}` currently always carries an
enumerable. The unified path needs the **file** adapter to expose a *path* and
the **HTTP/cache** adapter a *drainable guarded stream*. This is a
**Source-boundary** contract change (the `Source` boundary owns and exports
`Response`): introduce a tagged body (e.g. `{:path, p}` vs `{:stream, wrapped}`)
or an added field, so `Request` can dispatch on it **without** learning
file-vs-http internals. `Source.body_limit_exceeded?/1` and
`Source.stream_error_reason/1` must keep working for the stream case and degrade
cleanly for the path case.

```
guarded fetch (WrappedStream: byte-count + early cancel at max_body_bytes)
  ├─ file source:        validated path → Image.open(path)   (new_from_file)
  └─ http / cache bytes: drain (fail-closed) → bin → Image.open(bin)  (new_from_buffer)
  → seekable libvips image (opened once, lazily; header only):
        1. read header dims + format  → max_input_pixels on ORIGINAL extent
        2. Processor passes {operations, source_format, original_dims} to the planner
        3. planner → {access, load_option}; reopen/decode with shrink:/scale: + access:
  → residual resize + crop/gravity coords adjusted for the achieved prescale
```

> The `image` library's default `access` is `:VIPS_ACCESS_RANDOM`, so the
> planner/processor must set `access:` **explicitly** for sequential chains; it
> is not the default.

### Decode planning stays a pure function over Plan operations

`ImagePipe.Transform.DecodePlanner` must **not** read a decoded `Vix.Vips.Image`
or classify source format itself: the Transform boundary is
`deps: [ImagePipe.Plan, ImagePipe.Telemetry]` (`lib/image_pipe/transform.ex`)
and must not depend on `Request`/`Source`. Source-format classification lives in
`ImagePipe.Request.SourceFormat` (Request boundary) and original dimensions are
read by `ImagePipe.Request.Processor`.

So the planner's signature changes to take **plain, product-neutral values
supplied by the caller**:

```
DecodePlanner.open_options(first_pipeline_operations, source_format, original_dims)
  :: {access :: :sequential | :random, load_option :: load_option()}
```

The Processor (Request boundary) does the *reading* — open the seekable source,
read header dims and format — then hands those values to the planner. The
planner remains a pure policy function: format gating + the shrink arithmetic.

The shrink policy:

- `load_shrink = min(wshrink, hshrink)` where `wshrink`/`hshrink` are
  `src_dim / target_dim` for the first-pipeline resize, computed against
  **orientation-corrected** axes (see [Orientation](#orientation)). Using `min`
  (per imgproxy `scale_on_load.go`) avoids over-shrinking when only one target
  axis is set.
- The planner emits a **per-format load option**, not a single `shrink:`:
  - **JPEG** → `shrink: n` where `n` is the largest of `{1,2,4,8}` not
    exceeding `load_shrink` (libjpeg IDCT block scaling).
  - **WebP / vector (SVG, PDF — only if those source formats are supported)** →
    `scale: 1 / load_shrink` (fractional pre-scale).
  - **PNG, HEIF/AVIF, and all other formats** → no shrink option
    (`load_shrink = 1`); full decode, residual resize only. (HEIF/AVIF embedded
    thumbnails are *not* used in this slice; the `image` open API exposes no
    shrink/scale/thumbnail knob for them. See
    [Out of scope](#out-of-scope).)
- When `load_shrink == 1` for any reason, the open is the plain seekable open
  with the chosen `access:` and no shrink/scale.

### Geometry adjustment after shrink-load (inside the Transform layer)

Request/source/response code must dispatch through `ImagePipe.Transform` and
must not name concrete operation modules (`Resize`, `Crop`, `Focus`, …). So the
**achieved prescale enters the Transform layer as a generic input** — a field on
`ImagePipe.Transform.State` (or a parameter to the execute entry point) — and
the adjustment math lives inside the transform/geometry modules, not in the
Processor.

Mirroring imgproxy `processing/scale_on_load.go`:

- After opening with shrink/scale, recompute the **actual achieved shrink** from
  the loaded dimensions (libvips may not hit the exact requested factor —
  JPEG quantizes to 1/2/4/8).
- **Divide the residual resize scale** by the achieved shrink so the
  high-quality resize finishes the downscale to the exact target. If the load
  shrink already hits the target exactly, skip the residual resize for that
  axis.
- **Rescale crop dimensions and absolute gravity offsets** by the achieved
  shrink (relative/focus-point offsets are unaffected). Round absolute offsets
  to avoid turning them into relative values.

### Orientation

The chosen manual `shrink:`/`scale:` load does **not** auto-rotate: plain
libvips loaders (and therefore `new_from_buffer`/`new_from_file`) only read the
EXIF `orientation` metadata; they do not apply it. `Image.open` even rejects an
`:autorotate` option (`deps/image/lib/image/options/open.ex`). ImagePipe applies
orientation explicitly via its own `AutoOrient` operation
(`Image.autorotate/1`). There is therefore **no double-application risk** and
nothing to "reconcile" at load time.

The real interaction is purely dimensional: stored pixel dimensions and
displayed (post-autorotate) dimensions differ for rotated images. The resize
target is expressed in displayed orientation, so:

- `load_shrink` must be computed comparing the target against the
  **orientation-corrected** source axes (swap width/height when the EXIF
  orientation implies a 90°/270° rotation), so a portrait-tagged landscape image
  is not shrunk against the wrong axis.
- `AutoOrient` continues to run as a normal pipeline step; the load is unchanged
  by it.

### Safety: input-pixel limit on original extent

`max_input_pixels` is currently validated **after** decode by reading
`Image.width × Image.height` of the opened image
(`lib/image_pipe/request/processor.ex`). With shrink-on-load the opened image is
already shrunk, so this would validate the *shrunk* size and let a
decompression bomb through.

**Fix:** validate `max_input_pixels` against the **original
`width × height`**, read from the lazily-opened seekable image *before* any
shrink is applied and *before* pixels are pulled. The limit is checked on the
**declared header values**, trusting the header — so a maliciously huge header
is rejected without attempting decode.

**Animation is out of scope.** ImagePipe loads inputs single-page (libvips'
default `n: 1`; the codebase requests no other page count anywhere), so animated
sources decode only their first frame and the output is static. The pixel limit
therefore applies to that single decoded page, which is sound: the other frames
are never decoded, so there is no frames-times-dimensions bomb to defend
against. A test confirms a multi-frame input (GIF/WebP/AVIF) is loaded
single-page so the limit cannot be bypassed via frame count. If frame
passthrough is ever added, the limit must become
`page_width × page_height × n_pages` — out of scope here.

Ordering is preserved so unsupported-format rejection and the input-pixel check
both happen **before** any pixel pull (the existing "unsupported format reported
before input-pixel limit" ordering test must be updated, not broken). For the
file-path case, the limit is enforced on the same bytes that get decoded; the
file is assumed immutable for the duration of the request (`stable: :trusted`
files), which the spec notes to acknowledge the open-vs-open TOCTOU window.

All other source-safety boundaries are unchanged and still occur before
generation: non-2xx status, content-type validation, `max_body_bytes` (now
enforced while draining into the buffer, with fail-closed mid-stream cancel),
and transport error wrapping. (Result-dimension limits are a separate,
*post-generation* gate — they run after transforms decide the output size — and
are unaffected by shrink-on-load.)

### Error-mapping and materialization coherence

- **Drain-time errors fail closed before decode** (above): the
  `prefer_source_body_limit`/`prefer_source_stream_error` checks move to wrap the
  drain result, and the `Source.StreamError` rescue/catch around
  `Image.open(stream)` becomes dead code and is removed.
- **Materialize-before-delivery stays for still-lazy sources.** For the
  file-path open (`new_from_file`, mmap) pixels are pulled lazily from the OS
  page cache, so a sequential pass still needs the materialize step before
  cache write / response headers (a disk read error can still surface after
  headers). The "remove the stream-only materialize coupling" cleanup applies
  only to the drained-buffer case; it must not remove materialization for the
  lazy file-path case.
- **Multi-pipeline `materialize_between_pipelines` is unchanged.** It copies the
  intermediate image to memory between pipelines and is independent of the
  decode-input shape.

### Telemetry

Emit shrink decisions through the **existing** `[:source, :fetch_decode]` span
metadata (`fetch_decode_stop_metadata/1`) rather than a new event: add
`load_option`/`achieved_shrink` and original/loaded dims (all product-neutral,
non-sensitive — decoded dimensions and operation params are explicitly fine to
emit). Do **not** attach achieved-shrink timing to per-operation
`[:transform, :operation]` spans (those reflect lazy pipeline construction, not
compute).

## Output equivalence contract

Full-decode-then-resize and shrink-load-then-residual-resize do **not** produce
byte-identical pixels — libjpeg IDCT block scaling is a different downsample
kernel than libvips' resize. The existing
`test/image_pipe/sequential_compatibility_test.exs` asserts pixel-exact equality
(`Image.get_pixel!`); that assertion is incompatible with shrink-on-load.

The new contract for a shrink-eligible downscale, versus the full-decode
baseline for the same plan, with **hard, deterministic gates**:

- **Output dimensions exactly equal.**
- **Alpha presence equal.**

and a **version-stable similarity gate** (raw per-pixel max-abs is too fragile
across libvips/libjpeg builds and must not be the gate):

- Compare the two outputs via a **coarse-downsample mean-absolute-error**
  (downscale both to a small fixed size, e.g. 32×32, then MAE) — and/or SSIM —
  which measures "same picture", not "same kernel".
- Gate on the **mean** (and optionally a high-percentile such as p99), never on
  the single-pixel maximum.
- Pin the concrete threshold in the spec/test **with the libvips version it was
  measured against**, chosen with generous margin (e.g. 3–5× the observed value)
  so a minor version bump does not flip the gate.

For non-shrink-eligible formats (PNG, HEIF/AVIF) and `load_shrink == 1`, the
path is unchanged and remains pixel-exact with prior behavior.

## ETag note

Decode strategy (`access`, `load_option`, buffering-vs-streaming) is internal
and stays out of **both** the cache key (`ImagePipe.Cache.Key`) and the ETag
(`source_seed + canonical plan + Accept`); no data-version bump is needed
(greenfield). One acknowledged subtlety: the ETag is an input-derived strong
validator and already excludes the libvips version. The perceptual-equivalence
contract widens this slightly — two deployments with different decode regimes
(shrink-on-load on/off, or different libvips versions) can emit the same ETag for
non-byte-identical bodies. This is not a new conflation in code (the ETag never
hashes the body), but the strong-validator semantics now assume a homogeneous
decode regime across a fleet; documented, not gated.

## Measurement

The acceptance criterion ("benchmarks/tests demonstrate reduced memory/CPU") is
met with a **deterministic gate** plus a **reported benchmark**:

- **Deterministic gate (the real signal):** assert that the shrink-loaded
  image's pre-residual-resize dimensions are `≈ original / achieved_shrink` —
  i.e. directly prove the full-resolution bitmap was never materialized. This is
  deterministic and not flaky.
- **Reported benchmark (non-gating):** a separate `async: false`,
  single-process measurement (or a `mix run` script outside the suite) that
  records libvips tracked memory deltas with the libvips operation cache
  disabled (`Vix.Vips.cache_set_max(0)` / `cache_set_max_mem(0)`), comparing old
  full-decode vs. new shrink-load for a large JPEG/WebP downscale, and documents
  representative numbers. **Do not** gate CI on `tracked_get_mem_highwater`
  (process-global, non-resettable, async-polluted — `deps/vix/lib/vix/vips.ex`)
  or on wall-clock time.

## Components touched

- `ImagePipe.Source` / `Source.Response` — tagged path-vs-stream body
  (Source-boundary contract change); `body_limit_exceeded?`/`stream_error_reason`
  handle both.
- `ImagePipe.Source.File` — resolve to a validated path for decode; keep
  `safe_path`/`regular_file`; stop forcing `File.stream!/3` on the decode path.
- `ImagePipe.Source.HTTP` / `WrappedStream` — bounded fail-closed drain-to-binary
  preserving byte-count and mid-stream cancel.
- `ImagePipe.Transform.DecodePlanner` — pure `{access, load_option}` over
  `(operations, source_format, original_dims)`, with format gating and the `min`
  shrink rule. No image/format reading.
- `ImagePipe.Request.Processor` — open the seekable source once (lazy), read
  header dims + format, validate `max_input_pixels` on original extent, call the
  planner, decode/reopen with the load option, and feed the achieved prescale
  into the Transform layer. Maps drain errors. Keeps materialize-before-delivery
  for the lazy file-path case only.
- `ImagePipe.Transform.State` / `transform/geometry.ex` — carry and apply the
  achieved prescale (residual resize, crop/gravity rescaling); the Processor must
  not name concrete operation modules.
- README / `docs/operational_notes.md` — format gating, equivalence contract,
  follow-up pointer.

These are contract-level; concrete module/function shapes are the plan's job.

## Testing

- **DecodePlanner (behavior, not keyword shape):** computed shrink factor per
  `(format, original_dims, target)` — JPEG quantization to 1/2/4/8, WebP/vector
  fractional `scale:`, PNG/HEIF/AVIF → no shrink, the `min` rule for single-axis
  targets, orientation-swapped axis selection. Assert the *decision*, not the
  literal option keyword ordering.
- **Safety:** `max_input_pixels` enforced on **original** extent with a
  shrink-eligible plan (a bomb is rejected and the error reports the *original*
  count, even though the shrunk image would be small); a **multi-frame**
  GIF/WebP/AVIF input asserting it is loaded single-page so the limit cannot be
  bypassed via frame count; a test (via a counting `image_open_module` stub or
  the decoded-dimension signal)
  that **no full-resolution materialization** occurs on rejection; a **wire-level**
  test that an oversized HTTP body fails with `:body_too_large` **before**
  decode/generation through the new drain step, and that the origin response is
  cancelled (not fully buffered); the unsupported-format-before-input-pixel
  ordering test updated for the new ordering.
- **Geometry (through a real plan/producer, never hand-built operation structs):**
  residual-resize math after a non-exact achieved shrink; crop-dimension and
  absolute-gravity-offset rescaling — exercised at the request/wire boundary with
  pixel decoding.
- **Wire-level request tests:** real `ImagePipe.call/2` for a large JPEG and
  WebP downscale — assert status, content type, exact output dimensions, alpha,
  and the coarse-downsample similarity gate vs. the full-decode baseline; a PNG
  downscale falls back (no shrink) and stays pixel-exact.
- **Equivalence test placement:** **delete**
  `sequential_compatibility_test.exs` (a now-pointless access-mode parity pin —
  the codebase moves to one decode path); put the surviving dimension/alpha-exact
  + similarity assertions in the wire-level `ImagePipe.call/2` tests, not in a
  unit test that hand-drives `Image.open` + `Chain.execute` + `Materializer`.
- **Measurement:** the deterministic decoded-dimension gate above; the reported
  benchmark is separate and non-gating.

## Out of scope

### Concurrent download-and-decode (seekable async source)

Tracked as [#139](https://github.com/hlindset/image_pipe/issues/139).

imgproxy v4's "parallel image downloading" wraps the HTTP response in an
**async buffer** that fills in the background and exposes **seekable readers**
(a read at a not-yet-downloaded offset blocks until it arrives), each wired to a
**custom seekable source** with both read and seek callbacks. This lets libvips
decode while bytes are still arriving and supports formats that seek back and
forth (HEIF/AVIF).

This is **not** a memory optimization — the async buffer still holds up to the
full compressed body, and back-seeking formats need it resident. Its payoff is
latency (overlap), origin connection reuse, and seek support. It also requires
extending the Vix NIF layer: Vix's only custom source today is the non-seekable
descriptor pipe, so a new seekable custom-source primitive (read + seek
callbacks re-entering the BEAM, backed by a blocking async-buffer process) would
be needed — a substantial systems effort with cross-thread callback,
backpressure, cancellation, and lifecycle concerns.

It is deferred to a dedicated follow-up. Crucially, it is **forward-compatible**
with this design: it only changes how bytes are delivered to the decoder. The
downstream "seekable source → header check → shrink → residual resize" pipeline
is identical, so the async source later drops in as a replacement for the HTTP
drain-to-buffer step with no change to planning, geometry, or safety.

### HEIF/AVIF embedded-thumbnail shrink

imgproxy uses libvips' `heifload thumbnail=true` / `thumbnail` machinery for
formats with embedded thumbnails. The `image` open API in this repo exposes no
shrink/scale/thumbnail knob for HEIF/AVIF (they decode via `from_binary` with
only `access`/`fail_on`). Supporting it would mean calling
`Vix.Vips.Operation.heifload_*` directly, bypassing `Image.open`, and is
deferred. HEIF/AVIF are treated as non-shrink-eligible in this slice.

### Temp-file spooling for HTTP

An alternative to in-memory buffering is spooling the HTTP body to a temp file
and using `new_from_file` (trading RAM for disk + cleanup). Not pursued now;
in-memory buffering bounded by `max_body_bytes` matches imgproxy and is simpler.
Noted as a future option if compressed-body memory pressure becomes real.

## Review cycle

v2 incorporates a 3-way parallel review with disjoint focus areas:

- **Vix/libvips correctness:** corrected the claim that the pipe loader "cannot
  shrink" (it is read-once, which defeats the header-then-reopen flow);
  separated integer `shrink:` (JPEG) from fractional `scale:` (WebP/vector);
  **removed the auto-orient double-application concern** (manual loaders do not
  auto-rotate; `Image.open` rejects `:autorotate`); **dropped HEIF/AVIF** from
  the shrink-eligible set (no shrink/scale knob in the `image` open API).
- **Architecture/boundaries:** kept `DecodePlanner` a **pure** function over
  Plan operations + caller-supplied `source_format`/`original_dims` (Transform
  boundary is `deps: [Plan, Telemetry]`); routed the prescale into the Transform
  layer as a generic input so the Processor never names concrete operation
  modules; named the `Source.Response` path-vs-stream contract change; specified
  fail-closed drain error mapping and which materialization survives; confirmed
  cache key/ETag stay decode-strategy-free and added the fleet-homogeneity
  caveat; routed shrink metadata through the existing `[:source, :fetch_decode]`
  span.
- **Tests/safety/measurement:** added the **multi-page/animated** input-pixel
  definition and test; replaced the vague pixel tolerance with a **version-stable
  coarse-downsample MAE/SSIM** gate (dimension+alpha as hard gates); **dropped
  `tracked_get_mem_highwater` as a CI gate** in favor of a deterministic
  decoded-dimension assertion plus a reported benchmark; chose to **delete**
  `sequential_compatibility_test.exs` rather than rewrite it; added the
  wire-level body-limit-before-decode test.
