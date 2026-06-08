# Imgproxy processing pipeline conformance

This document maps imgproxy's internal **processing pipeline** — the fixed,
ordered sequence of stages imgproxy runs per image — to where and how ImagePipe
realizes each stage. It is the counterpart to
[imgproxy_support_matrix.md](imgproxy_support_matrix.md): the support matrix
answers *"do we accept option/config X?"*, this document answers *"do we run the
same processing stages, in a compatible order, and where in our architecture?"*

## Three axes of conformance

Imgproxy conformance has three independent axes. Each is documented in a
different place, because each answers a different question:

| Axis | Question | Documented in |
| --- | --- | --- |
| **Surface** | Do we accept the same URL options / config? | [imgproxy_support_matrix.md](imgproxy_support_matrix.md) |
| **Stage / order** | Do we run the same pipeline stages, in a compatible order, realized where? | **this document** |
| **Behavioral / pixel** | Does a matching stage produce matching output? | wire conformance tests (`test/image_pipe/imgproxy_wire_conformance_test.exs`) + the "Diverges" notes in both docs |

A single feature can pass one axis and fail another. `fixSize` (below) is
*surface*-invisible (no option/config), *stage*-conformant (we clamp), and
*behaviorally* equivalent for WebP/AVIF — it only becomes legible once you look
at the stage axis.

## Why a separate view from the support matrix

The support matrix is keyed on imgproxy's **configurable surface** (`IMGPROXY_*`
env vars and URL options). Most pipeline stages have **no config knob and no URL
option** — `fixSize`, `scaleOnLoad`, `colorspaceToProcessing`, `cropToResult`
are internal steps. They have no row in the support matrix, yet they are exactly
where compatibility lives or breaks. This document gives those stages a home.

It also surfaces an architectural fact the support matrix cannot: ImagePipe does
**not** realize every imgproxy "pipeline step" inside its transform chain. Some
are realized at other boundaries — decode planning, the output boundary, the
encoder finalize step. The "Realized in" column below makes that mapping
explicit.

## Status legend

| Status | Meaning |
| --- | --- |
| ✅ Matches | ImagePipe runs an equivalent stage with compatible semantics. |
| ⚠️ Diverges | ImagePipe runs a related stage, but with a deliberate behavioral difference (see notes). |
| ⭕ Missing | Not implemented in the current ImagePipe surface. |
| 🛑 Out of scope | Excluded from ImagePipe's library surface (e.g. SVG/vector, watermark, video). |

## Imgproxy's pipeline

From `local/imgproxy-master/processing/processing.go`:

```text
mainPipeline (processing.go:21-35), applied per frame:
  vectorGuardScale · trim · scaleOnLoad · colorspaceToProcessing ·
  crop · scale · rotateAndFlip · cropToResult · applyFilters ·
  extend · extendAspectRatio · padding · fixSize · flatten · watermark

finalizePipeline (processing.go:42-45), applied before save:
  colorspaceToResult · stripMetadata
```

ImagePipe does not execute imgproxy's pipeline directly. It parses to a
product-neutral `ImagePipe.Plan` whose transform order is fixed by the
parser/plan layer (URL option order is irrelevant — see
[transform_operations.md](transform_operations.md) and
[imgproxy_path_api.md](imgproxy_path_api.md)), then executes that plan across
three architectural layers: **decode planning**, the **transform chain**, and
the **output boundary**. The table below maps each imgproxy stage onto whichever
ImagePipe layer realizes it.

## Main pipeline

| # | imgproxy stage | Realized in ImagePipe | Status | Notes |
| --- | --- | --- | --- | --- |
| 1 | `vectorGuardScale` | — | 🛑 | SVG/vector input is rejected after decode identifies an SVG loader, before transforms. No vector pre-scale stage. (support matrix → "Source input formats") |
| 2 | `trim` | — | ⭕ | `trim`/`t` not implemented (support matrix → Resize/geometry). Needs full-image memory + a trim operation. |
| 3 | `scaleOnLoad` | **decode planning** — `lib/image_pipe/transform/decode_planner.ex` | ✅ | Shrink-on-load computed as a libvips load option (`shrink`/`scale`), not a transform op. Decode opens `:sequential`; see [transform_operations.md](transform_operations.md) → "Decode planning". |
| 4 | `colorspaceToProcessing` | `lib/image_pipe/transform/operation/normalize_color_profile.ex` | ⚠️ | imgproxy color-manages **every** image into a working space; ImagePipe converts only when `scp` is on (issue #124). With `scp:0` + a tone effect on a wide-gamut source, effects run in the source profile space. |
| 5 | `crop` | `lib/image_pipe/transform/operation/crop.ex` | ✅ | Pre-resize crop with anchor / focal-point / smart / object gravity. |
| 6 | `scale` | `lib/image_pipe/transform/operation/resize.ex` | ✅ | `fit`/`fill`/`fill-down`/`force`/`auto`, enlarge, min-width/height, zoom, dpr. Pro resizing-algorithm selection (`ra`) is missing. |
| 7 | `rotateAndFlip` | `lib/image_pipe/transform/orientation.ex`, `.../operation/rotate.ex`, `.../operation/flip.ex` | ✅ | Suborder: auto-orient → rotate → flip (matches imgproxy; see [transform_operations.md](transform_operations.md) → "Orientation operations"). EXIF auto-orient is the default. |
| 8 | `cropToResult` | `lib/image_pipe/transform/operation/crop.ex` (result crop after a fill-style resize) | ✅ | `Resize` deliberately does **not** crop (`resize.ex` moduledoc): for `fill`/`fill_down` it resizes to cover dimensions, then plan execution emits a **separate** crop operation to the result size. |
| 9 | `applyFilters` | `lib/image_pipe/transform/operation/{blur,sharpen,pixelate,brightness,contrast,saturation,monochrome,duotone}.ex` | ✅ | Supported effect subset. Effect order is documented in [transform_operations.md](transform_operations.md) → "Effect operations". Pro filters (`unsharp_masking`, `blur_areas`, `blur_detections`, `colorize`, `gradient`) are missing. |
| 10 | `extend` | `lib/image_pipe/transform/operation/extend_canvas.ex` | ✅ | Canvas extension with anchor gravity and offsets. |
| 11 | `extendAspectRatio` | `lib/image_pipe/transform/operation/extend_canvas.ex` (`{:aspect_ratio, ratio}` rule) | ✅ | `extend_ar`/`exar`; no-op when a resize dimension is auto/zero. `fp` extend-gravity not supported (matches `extend`). |
| 12 | `padding` | `lib/image_pipe/transform/operation/padding.ex` | ✅ | CSS-style shorthand, effective DPR scaling. |
| 13 | `fixSize` | **output boundary** — `lib/image_pipe/output/clamp.ex` (#150) | ✅ | Format-aware encoder dimension clamp. Realized at the **Output boundary**, not the transform chain: after final dimensions are known, the realized image is uniformly downscaled to the chosen encoder's hard limit (WebP 16383, AVIF 16384). Mirrors `processing/fix_size.go` (`fixWebpSize`/`fixHeifSize`). Emits `[:output, :clamp]` ([telemetry.md](telemetry.md)); covered by `test/image_pipe/imgproxy_wire_conformance_test.exs`. The `max_pixels`/sqrt branch (imgproxy's `fixGifSize`) is deferred to #165. |
| 14 | `flatten` | `lib/image_pipe/transform/operation/background.ex` | ✅ | Alpha flatten onto `background`/`background_alpha` (`bg`/`bga`); default black. |
| 15 | `watermark` | — | 🛑 | Watermark processing is not modeled (support matrix → "Background, effects, and overlays"). |

## Finalize pipeline

| # | imgproxy stage | Realized in ImagePipe | Status | Notes |
| --- | --- | --- | --- | --- |
| 16 | `colorspaceToResult` | `lib/image_pipe/transform/operation/normalize_color_profile.ex` (when `scp`) | ⚠️ | imgproxy always converts to the output colorspace before save; ImagePipe has no unconditional output-colorspace conversion — same `scp`-gated divergence as stage 4 (issue #124). |
| 17 | `stripMetadata` | **encoder finalize** — `lib/image_pipe/output/encoder.ex` | ✅ | Strips EXIF/XMP/IPTC at encode time. **Diverges** on `keep_copyright` (preserves EXIF copyright/artist only; imgproxy keeps full XMP/IPTC blobs) and on the `scp`-gated ICC handling. See support matrix → "Metadata, color, and source decoding". |

## Surrounding stages (outside the two pipelines)

imgproxy's `ProcessImage`/`prepare` wrap the pipelines with load, size-gating,
format determination, and save. ImagePipe realizes these too, mostly at request
and output boundaries:

| imgproxy stage | Realized in ImagePipe | Status | Notes |
| --- | --- | --- | --- |
| Initial load + source-resolution gate (`MaxSrcResolution`) | decode + `max_input_pixels` (hard error) | ✅ | The image-bomb gate is a hard error, not a downscale — matches imgproxy. `max_body_bytes` caps the fetched body. |
| Output format determination | `lib/image_pipe/output/negotiation.ex`, `lib/image_pipe/output/policy.ex` | ✅ | `Accept` negotiation for AVIF/WebP with `Vary: Accept`; explicit `@extension`/`.extension` bypasses negotiation. JXL, `enforce_*`, and `preferred_formats` are missing. |
| Host result-dimension cap (`limitScale`, `processing/prepare.go`) | `lib/image_pipe/request/processor.ex` (`check_result_*`) | ⚠️ | imgproxy **downscales** the result to fit `max_result_*`; ImagePipe currently **errors** (`{:result_limit, …}`). Issue #165 changes this to downscale-and-serve, reusing the #150 `Output.Clamp` mechanism with `min(host_max, encoder_limit)`. |
| Save / encode | `lib/image_pipe/output/encoder.ex` | ✅ | Streams the encoded result. Advanced/codec-specific encoder knobs are missing (support matrix → "Advanced encoder options"). |

## Key takeaways

- **Order is plan-owned, not URL-owned.** imgproxy's stage order is realized by
  ImagePipe's fixed `ImagePipe.Plan` transform order; URL option order does not
  define it. See [transform_operations.md](transform_operations.md) and
  [imgproxy_path_api.md](imgproxy_path_api.md).
- **Not every imgproxy stage is a transform op.** `scaleOnLoad` is decode
  planning, `fixSize` is the output boundary, `colorspaceToResult`/
  `stripMetadata` are encoder finalize. The "Realized in" column is the map.
- **The standing divergences are color management (#124) and the host result
  cap (#165).** Both are tracked; everything else either matches or is an
  explicitly out-of-scope/missing surface documented in the support matrix.
