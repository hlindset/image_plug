# Imgproxy Support Matrix

This matrix compares ImagePlug's current `ImagePlug.Parser.Imgproxy` support
with imgproxy's processing URL surface.

ImagePlug intentionally treats imgproxy URLs as a compatibility parser for a
product-neutral `ImagePlug.Plan`. Supported options translate cleanly into
canonical plan/output/cache/response fields. Unsupported options are rejected
before origin fetch or cache lookup; they are not silently ignored.

## Status Legend

| Status | Meaning |
| --- | --- |
| Supported | Parsed and translated into `ImagePlug.Plan` or another request facet. |
| Partial | Some imgproxy syntax or semantics are supported, but not the whole option. |
| Rejected | Recognized or intentionally documented as unsupported, returning an error before side effects. |
| Missing | Not implemented in the current parser/plan/runtime surface. |
| Out of scope | Deliberately excluded for now; currently only video-related features use this status. |

## URL Shape, Source, And Security

| Imgproxy feature | Status | Notes |
| --- | --- | --- |
| Required signature path segment | Supported | `_` and `unsafe` are accepted when signing is disabled; HMAC and exact trusted signatures are accepted when signing is configured. Trusted-only config accepts only exact trusted signatures. This is intentionally narrower than upstream disabled-signing behavior. |
| HMAC URL signatures | Supported | Imgproxy parser verifies raw/unpadded Base64URL HMAC-SHA256 signatures with hex key/salt pairs, optional truncation, rotation pairs, exact trusted signatures, and imgproxy-compatible `fixPath` before verification. Signature failures return 403. |
| Plain source URLs via `/plain/` | Partial | ImagePlug treats the value as path segments resolved against configured `root_url`; arbitrary absolute source URLs are not modeled. |
| Plain source `@extension` | Supported | Overrides option format and bypasses `Accept` negotiation. |
| Base64 encoded source URL | Missing | No encoded source parsing or absolute URL source model. |
| Encrypted `/enc/` source URL | Missing | Pro feature; requires source decryption and signed URL safety. |
| AES-CBC source URL encryption helpers | Missing | Should remain parser/runtime source-layer support, not transform support. |
| Custom argument separator | Missing | Parser currently uses `:`. |
| Processing option order independence | Supported | URL option order does not define transform order. |
| Pipeline separator `-` | Supported | Separates non-empty pipeline groups. |

## Resize, Geometry, And Orientation

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `resize` | `rs` | Supported | Includes optional resize-tail `enlarge`, `extend`, and extend gravity. |
| `size` | `s` | Supported | Same field mapping as imgproxy size meta-option. |
| `resizing_type` | `rt` | Supported | `fit`, `fill`, `fill-down`, `force`, and `auto`. |
| `resizing_algorithm` | `ra` | Missing | No algorithm selection in plan or transform execution. |
| `width` | `w` | Supported | Non-negative integer; `0` means auto. |
| `height` | `h` | Supported | Non-negative integer; `0` means auto. |
| `min-width` | `min_width`, `mw` | Supported | Non-negative integer. |
| `min-height` | `min_height`, `mh` | Supported | Non-negative integer. |
| `zoom` | `z` | Supported | Single value or separate x/y factors. |
| `dpr` | | Supported | Affects resize sizing and cache key data. |
| `enlarge` | `el` | Supported | Boolean. |
| `extend` | `ex` | Supported | Canvas extension with anchor gravity and offsets. |
| `extend_aspect_ratio` | `extend_ar`, `exar` | Partial | Supported as ratio canvas extension; imgproxy's boolean argument form is not modeled. |
| `gravity` anchors | `g` | Supported | `ce`, `no`, `so`, `ea`, `we`, `noea`, `nowe`, `soea`, `sowe`. |
| `gravity:fp` | `g:fp` | Supported | Focal point coordinates from `0.0` to `1.0`. |
| `gravity:sm` | `g:sm` | Rejected | Parsed but rejected as unsupported smart gravity. |
| `gravity:obj` | | Missing | Pro object-detection gravity. |
| `gravity:objw` | | Missing | Pro object-detection gravity with weights. |
| `objects_position` | `obj_pos`, `op` | Missing | Pro object-detection positioning. |
| `crop` | `c` | Supported | Absolute, relative, or full-axis dimensions; anchor/focal/smart gravity parsing. Smart gravity is rejected at planning. |
| `crop_aspect_ratio` | `crop_ar`, `car` | Missing | Documented as unsupported in current ImagePlug docs. |
| `trim` | `t` | Missing | Requires full-image memory behavior and trim operation. |
| `padding` | `pd` | Supported | CSS-style sparse shorthand, accumulated field behavior, effective DPR scaling, and `padding:` no-op compatibility. |
| `auto_rotate` | `ar` | Supported | Omitted argument enables auto-orient; boolean form supported. |
| `rotate` | `rot` | Supported | Right-angle multiples normalize to `0`, `90`, `180`, or `270`. |
| `flip` | `fl` | Supported | No args means both axes; one or two booleans are supported. |

## Background, Effects, And Overlays

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `background` | `bg` | Supported | RGB decimal and 3/6 digit hex colors; `background:` clears previous background color and alpha. |
| `background_alpha` | `bga` | Supported | Applies an alpha channel to the accumulated background color; without an explicit background color, uses imgproxy's default black background. |
| `adjust` | `a` | Missing | Pro meta-option for brightness, contrast, and saturation. |
| `brightness` | `br` | Missing | Pro color adjustment. |
| `contrast` | `co` | Missing | Pro color adjustment. |
| `saturation` | `sa` | Missing | Pro color adjustment. |
| `monochrome` | `mc` | Missing | Pro color effect. |
| `duotone` | `dt` | Missing | Pro color effect. |
| `blur` | `bl` | Missing | No blur operation yet. |
| `sharpen` | `sh` | Missing | No sharpen operation yet. |
| `pixelate` | `pix` | Missing | No pixelate operation yet. |
| `unsharp_masking` | `ush` | Missing | Pro advanced sharpening controls. |
| `blur_areas` | `ba` | Missing | Pro area blur. |
| `blur_detections` | `bd` | Missing | Pro object-detection blur. |
| `draw_detections` | `dd` | Missing | Pro object-detection debug overlay. |
| `crop_objects` | `co` | Missing | Pro object-detection crop. |
| `colorize` | `col` | Missing | Pro overlay effect. |
| `gradient` | `gr` | Missing | Pro gradient overlay. |
| `watermark` | `wm` | Missing | Base watermark semantics are not modeled. |
| `watermark_url` | `wmu` | Missing | Pro custom watermark source. |
| `watermark_text` | `wmt` | Missing | Pro generated watermark image. |
| `watermark_size` | `wms` | Missing | Pro watermark sizing. |
| `watermark_rotate` | `wm_rot`, `wmr` | Missing | Pro watermark rotation. |
| `watermark_shadow` | `wmsh` | Missing | Pro watermark shadow. |
| `style` | `st` | Missing | Pro SVG-specific style injection. |

## Metadata, Color, And Source Decoding

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `strip_metadata` | `sm` | Missing | No request-level metadata stripping override. |
| `keep_copyright` | `kcr` | Missing | Depends on metadata stripping support. |
| `dpi` | | Missing | Pro metadata rewrite. |
| `strip_color_profile` | `scp` | Missing | No color profile transform/output control. |
| `preserve_hdr` | `ph` | Missing | No HDR preservation toggle. |
| `color_profile` | `cp`, `icc` | Missing | Pro profile conversion/embedding. |
| `enforce_thumbnail` | `eth` | Missing | No embedded thumbnail decode selection. |
| `page` | `pg` | Missing | Pro paginated/animated source selection. |
| `pages` | `pgs` | Missing | Pro multi-page stacking. |
| `disable_animation` | `da` | Missing | Pro animation handling. |

## Output And Encoding

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `quality` | `q` | Supported | `0` means configured default; `1..100` supported. |
| `format_quality` | `fq` | Partial | One `<format>:<quality>` pair per option segment; repeated segments merge. Variadic pairs in one segment are not supported. |
| `autoquality` | `aq` | Missing | Pro multi-encode quality search. |
| `max_bytes` | `mb` | Missing | No iterative encode degradation. |
| `jpeg_options` | `jpgo` | Missing | Pro advanced JPEG encoder controls. |
| `png_options` | `pngo` | Missing | Pro advanced PNG encoder controls. |
| `webp_options` | `webpo` | Missing | Pro advanced WebP encoder controls. |
| `avif_options` | `avifo` | Missing | Pro advanced AVIF encoder controls. |
| `format` | `f`, `ext` | Partial | `webp`, `avif`, `jpeg`, `jpg`, and `png` supported. `best` parses but is rejected. |
| Extension path suffix | | Partial | Plain `@extension` supported. Encoded-source `.extension` is not supported because encoded source URLs are missing. |
| Automatic output via `Accept` | | Supported | Omitted format negotiates AVIF/WebP and uses `Vary: Accept`. |
| `best` output | | Rejected | Parsed as an output value, rejected by planning. |

## Video

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `video_thumbnail_second` | `vts` | Out of scope | Pro video source support. |
| `video_thumbnail_keyframes` | `vtk` | Out of scope | Pro video source support. |
| `video_thumbnail_tile` | `vtt` | Out of scope | Pro video sprite generation. |
| `video_thumbnail_animation` | `vta` | Out of scope | Pro video animation generation. |

## Fallback, Raw, And Request Policy

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `fallback_image_url` | `fiu` | Missing | Pro fallback source behavior. |
| `skip_processing` | `skp` | Missing | No source-format raw pass-through path. |
| `raw` | | Missing | Documented as unsupported; would alter request safety and streaming model. |
| `cachebuster` | `cb` | Supported | Participates in cache key data, not transforms. |
| `expires` | `exp` | Supported | Rejects expired requests before origin/cache side effects. |
| `filename` | `fn` | Supported | Percent-decoded or URL-safe Base64 filename stem. |
| `return_attachment` | `att` | Supported | Controls `Content-Disposition` disposition. |
| `preset` | `pr` | Partial | Normal processing URLs support configured named presets, multiple names in one segment, `default` automatic expansion, nested presets with recursive re-entry skipped, and documented chained-pipeline merge semantics. Presets-only mode, info endpoint presets, env/file loading, and custom separators are not supported. |
| `hashsum` | `hs` | Missing | Pro source integrity check. |

## Security Limit Overrides

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `max_src_resolution` | `msr` | Missing | Security override; should require explicit opt-in if added. |
| `max_src_file_size` | `msfs` | Missing | Security override; should require explicit opt-in if added. |
| `max_animation_frames` | `maf` | Missing | Animation support is not modeled. |
| `max_animation_frame_resolution` | `mafr` | Missing | Animation support is not modeled. |
| `max_result_dimension` | `mrd` | Missing | Security override; should require explicit opt-in if added. |

## Presets

| Imgproxy feature | Status | Notes |
| --- | --- | --- |
| Named presets | Supported | Configured through `imgproxy: [presets: %{name => options}]`; expanded while parsing normal processing URLs. |
| Multiple preset arguments | Supported | `pr:thumb:sharp` applies each named preset in order. |
| `default` preset | Supported | Applied before URL options on every normal processing request. URL fields can override fields in the same merged group. |
| Presets referencing presets | Supported | Presets may use `preset`/`pr`; recursive re-entry is skipped to match imgproxy behavior. |
| Preset chained pipelines | Partial | Supports documented Pro merge semantics for preset values containing `-` when the referenced options are otherwise supported by ImagePlug. |
| Presets-only mode | Missing | Deliberately excluded from this slice. |
| Info endpoint presets | Missing | ImagePlug does not currently expose imgproxy info endpoints. |
| Preset env/file loading | Missing | `IMGPROXY_PRESETS`, `IMGPROXY_PRESETS_SEPARATOR`, and `IMGPROXY_PRESETS_PATH` parity is excluded; pass already-materialized presets through config instead. |

## Suggested Next Additions

The highest-value additions that fit ImagePlug's current architecture are:

1. Base64-encoded source URLs, if ImagePlug should support absolute upstream URLs.
2. Blur and sharpen as product-neutral transform operations.
3. Metadata stripping and color profile policy under output/encoding.
4. `max_bytes`, if iterative encoding is acceptable for the runtime cost.

Object detection, SVG style injection, custom watermark sources, and advanced
encoder knobs are missing today. If implemented, they should stay isolated in
compatibility/parser or focused runtime layers unless their semantics are
product-neutral and reusable. Video processing remains deliberately out of scope
for now.
