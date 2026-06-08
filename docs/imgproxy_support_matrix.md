# Imgproxy support matrix

This matrix compares ImagePipe's current `ImagePipe.Parser.Imgproxy` support
with Imgproxy's processing URL and configuration surfaces.

ImagePipe intentionally treats Imgproxy URLs as a compatibility parser for a
product-neutral `ImagePipe.Plan`. Supported options translate cleanly into
canonical plan/output/cache/response fields. Unsupported options fail before
source fetch or cache lookup. ImagePipe doesn't ignore them.

Conformance has three axes. This document covers two of them; the third lives in
the test suite:

| Axis | Question | Where |
| --- | --- | --- |
| **Surface** | Do we accept the same URL options / config? | the option/config tables below |
| **Stage / order** | Do we run the same processing stages, in a compatible order, realized where? | [Processing pipeline conformance](#processing-pipeline-conformance) |
| **Behavioral / pixel** | Does a matching stage produce matching output? | wire conformance tests (`test/image_pipe/imgproxy_wire_conformance_test.exs`) + the "Diverges" notes throughout |

A single feature can pass one axis and fail another: `fixSize` (in the pipeline
section) is *surface*-invisible (no option/config), *stage*-conformant, and
*behaviorally* equivalent for WebP/AVIF — it only becomes legible on the stage
axis. References to imgproxy source below use imgproxy's own repository layout
(`processing/…` in `github.com/imgproxy/imgproxy`); ImagePipe doesn't vendor it.

## Processing pipeline conformance

imgproxy processes each image through a fixed, ordered pipeline. Most stages have
no env var and no URL option, so they have no row in the configuration/URL tables
below — yet they are exactly where compatibility lives. This section maps each
imgproxy stage onto the ImagePipe layer that realizes it.

ImagePipe doesn't execute imgproxy's pipeline directly: it parses to a
product-neutral `ImagePipe.Plan` whose transform order is fixed by the
parser/plan layer (URL option order is irrelevant — see
[transform_operations.md](transform_operations.md) and
[imgproxy_path_api.md](imgproxy_path_api.md)), then executes that plan across
three layers — **decode planning**, the **transform chain**, and the **output
boundary**. The diagram colours stages by which layer realizes them; the tables
carry the detail.

```mermaid
flowchart TD
    subgraph main["mainPipeline · applied per frame"]
        direction TB
        A1["1 vectorGuardScale ⭕"] --> A2["2 trim ⭕"] --> A3["3 scaleOnLoad ✅"]
        A3 --> A4["4 colorspaceToProcessing ⚠️"] --> A5["5 crop ✅"] --> A6["6 scale ✅"]
        A6 --> A7["7 rotateAndFlip ✅"] --> A8["8 cropToResult ✅"] --> A9["9 applyFilters ✅"]
        A9 --> A10["10 extend ✅"] --> A11["11 extendAspectRatio ✅"] --> A12["12 padding ✅"]
        A12 --> A13["13 fixSize ✅"] --> A14["14 flatten ✅"] --> A15["15 watermark ⭕"]
    end
    subgraph fin["finalizePipeline · before save"]
        direction TB
        F1["16 colorspaceToResult ⚠️"] --> F2["17 stripMetadata ✅"]
    end
    A15 --> F1

    classDef decode fill:#dbeafe,stroke:#2563eb,color:#1e3a8a;
    classDef chain fill:#dcfce7,stroke:#16a34a,color:#14532d;
    classDef output fill:#ffedd5,stroke:#ea580c,color:#7c2d12;
    classDef none fill:#f3f4f6,stroke:#9ca3af,color:#6b7280;

    class A3 decode;
    class A4,A5,A6,A7,A8,A9,A10,A11,A12,A14,F1 chain;
    class A13,F2 output;
    class A1,A2,A15 none;
```

**Colour = ImagePipe layer:** 🟦 decode planning · 🟩 transform chain · 🟧 output
boundary (clamp / encoder finalize) · ⬜ not realized.
**Emoji = conformance:** ✅ matches · ⚠️ diverges · ⭕ missing (in scope, not built).

### Main pipeline

imgproxy's `mainPipeline` (`processing/processing.go`), applied per frame:

| # | imgproxy stage | Realized in ImagePipe | Status | Notes |
| --- | --- | --- | --- | --- |
| 1 | `vectorGuardScale` | — | ⭕ | Gated on SVG/vector input support, which isn't implemented yet (SVG is rejected after decode identifies an SVG loader, before transforms). In scope; this pre-scale stage follows once SVG input lands. (see "Source input formats") |
| 2 | `trim` | — | ⭕ | `trim`/`t` not implemented (see "Resize, geometry, and orientation"). Needs full-image memory + a trim operation. |
| 3 | `scaleOnLoad` | **decode planning** — `lib/image_pipe/transform/decode_planner.ex` | ✅ | Shrink-on-load computed as a libvips load option (`shrink`/`scale`), not a transform op. Decode opens `:sequential`. |
| 4 | `colorspaceToProcessing` | `lib/image_pipe/transform/operation/normalize_color_profile.ex` | ⚠️ | imgproxy color-manages **every** image into a working space; ImagePipe converts only when `scp` is on (issue #124). With `scp:0` + a tone effect on a wide-gamut source, effects run in the source profile space. |
| 5 | `crop` | `lib/image_pipe/transform/operation/crop.ex` | ✅ | Pre-resize crop with anchor / focal-point / smart / object gravity. |
| 6 | `scale` | `lib/image_pipe/transform/operation/resize.ex` | ✅ | `fit`/`fill`/`fill-down`/`force`/`auto`, enlarge, min-width/height, zoom, dpr. Pro `resizing_algorithm` (`ra`) missing. |
| 7 | `rotateAndFlip` | `lib/image_pipe/transform/orientation.ex`, `.../operation/rotate.ex`, `.../operation/flip.ex` | ✅ | Suborder: auto-orient → rotate → flip. EXIF auto-orient is the default. |
| 8 | `cropToResult` | `lib/image_pipe/transform/operation/crop.ex` (result crop after a fill-style resize) | ✅ | `Resize` deliberately does **not** crop: for `fill`/`fill_down` it resizes to cover dimensions, then plan execution emits a **separate** crop to the result size. |
| 9 | `applyFilters` | `lib/image_pipe/transform/operation/{blur,sharpen,pixelate,brightness,contrast,saturation,monochrome,duotone}.ex` | ✅ | Supported effect subset; order documented in [transform_operations.md](transform_operations.md). Pro filters (`unsharp_masking`, `blur_areas`, `colorize`, `gradient`) missing. |
| 10 | `extend` | `lib/image_pipe/transform/operation/extend_canvas.ex` | ✅ | Canvas extension with anchor gravity and offsets. |
| 11 | `extendAspectRatio` | `lib/image_pipe/transform/operation/extend_canvas.ex` (`{:aspect_ratio, ratio}` rule) | ✅ | `extend_ar`/`exar`; no-op when a resize dimension is auto/zero. `fp` extend-gravity not supported. |
| 12 | `padding` | `lib/image_pipe/transform/operation/padding.ex` | ✅ | CSS-style shorthand, effective DPR scaling. |
| 13 | `fixSize` | **output boundary** — `lib/image_pipe/output/clamp.ex` (#150) | ✅ | Format-aware encoder dimension clamp. Realized at the **Output boundary**, not the transform chain: the realized image is uniformly downscaled to the chosen encoder's hard limit (WebP 16383, AVIF 16384). Mirrors imgproxy's `processing/fix_size.go` (`fixWebpSize`/`fixHeifSize`). Emits `[:output, :clamp]` ([telemetry.md](telemetry.md)); covered by the wire conformance tests. The host `max_result_*` caps fold into this same clamp via `min(host, encoder)` (#165); ImagePipe's result-pixel cap uses an **independent linear-dimension + sqrt-pixel** rule, deliberately **not** `fixGifSize`'s combined-sqrt (which can leave a result over the dimension limit). |
| 14 | `flatten` | `lib/image_pipe/transform/operation/background.ex` | ✅ | Alpha flatten onto `background`/`background_alpha` (`bg`/`bga`); default black. |
| 15 | `watermark` | — | ⭕ | In scope, not yet implemented (consistent with the watermark rows in "Background, effects, and overlays" and "Watermark defaults and custom watermark cache"). |

### Finalize pipeline

imgproxy's `finalizePipeline` (`processing/processing.go`), applied before save:

| # | imgproxy stage | Realized in ImagePipe | Status | Notes |
| --- | --- | --- | --- | --- |
| 16 | `colorspaceToResult` | `lib/image_pipe/transform/operation/normalize_color_profile.ex` (when `scp`) | ⚠️ | imgproxy always converts to the output colorspace before save; ImagePipe has no unconditional conversion — same `scp`-gated divergence as stage 4 (issue #124). |
| 17 | `stripMetadata` | **encoder finalize** — `lib/image_pipe/output/encoder.ex` | ✅ | Strips EXIF/XMP/IPTC at encode. **Diverges** on `keep_copyright` (preserves EXIF copyright/artist only; imgproxy keeps full XMP/IPTC) and on the `scp`-gated ICC handling. See "Metadata, color, and source decoding". |

### Surrounding stages

imgproxy wraps the pipelines with load, size-gating, format determination, and
save. ImagePipe realizes these at request and output boundaries:

| imgproxy stage | Realized in ImagePipe | Status | Notes |
| --- | --- | --- | --- |
| Initial load + source-resolution gate (`MaxSrcResolution`) | decode + `max_input_pixels` (hard error) | ✅ | The image-bomb gate is a hard error, not a downscale — matches imgproxy. `max_body_bytes` caps the fetched body. |
| Output format determination | `lib/image_pipe/output/negotiation.ex`, `lib/image_pipe/output/policy.ex` | ✅ | `Accept` negotiation for AVIF/WebP with `Vary: Accept`; explicit `@extension`/`.extension` bypasses it. JXL, `enforce_*`, `preferred_formats` missing. |
| Host result-dimension cap (`limitScale`, `processing/prepare.go`) | `lib/image_pipe/output/clamp.ex` via the producer (`min(host max_result_*, encoder_limit)`) | ✅ | imgproxy downscales the result to fit `max_result_*`; ImagePipe matches for the common no-padding/no-extend request (#165), reusing the #150 `Output.Clamp` — byte-intent identical to `limitScale`'s linear `downScale = maxResultDim/max(outW,outH)` (`prepare.go:247`) when caps are equal and a dimension binds. **Diverges (superset):** ImagePipe honors independent `max_result_width`/`max_result_height` and a result `max_result_pixels` cap (sqrt), where imgproxy's `limitScale` has a single `MaxResultDimension` and no result-pixel cap. **Diverges (composition):** ImagePipe clamps the **composited** final image, whereas imgproxy folds the downscale into the resize scale and re-applies padding/extend at the reduced scale (`prepare.go:233-263`) — both land ≤ cap, but padded/extended requests differ in the **content-to-padding ratio of the final frame**. ImagePipe mirrors imgproxy's per-axis sub-1px floor (`prepare.go:252-258`) via `max(scale, 1/dim)`; in the extreme-aspect 1px regime the realized pixels can still differ for the same composited-vs-fold-back reason. |
| Save / encode | `lib/image_pipe/output/encoder.ex` | ✅ | Streams the encoded result. Advanced/codec-specific encoder knobs missing (see "Advanced encoder options"). |

### Key takeaways

- **Order is plan-owned, not URL-owned** — imgproxy's stage order is realized by
  ImagePipe's fixed `ImagePipe.Plan` transform order; URL option order doesn't
  define it.
- **Not every imgproxy stage is a transform op** — `scaleOnLoad` is decode
  planning, `fixSize` is the output boundary, `stripMetadata`/`colorspaceToResult`
  are encoder finalize. The "Realized in" column is the map.
- **The standing divergence is color management (#124).** The host result cap now
  downscales to match imgproxy (#165), with a deliberate, strictly-safe superset:
  independent per-axis width/height + a result-pixel cap, and a composited-image
  clamp point. Everything else either matches or is an explicitly missing/out-of-scope
  surface documented in the tables below.

## Status legend

The pipeline section above uses ✅ matches / ⚠️ diverges / ⭕ missing. The
configuration and URL/option tables below use a finer-grained legend:

| Status | Meaning |
| --- | --- |
| ✅ Supported | The parser translates this into `ImagePipe.Plan` or another request facet. |
| ⚠️ Partial | The parser supports some Imgproxy syntax or semantics, but not the whole option. |
| 🔗 URL-only | ImagePipe supports the request option, but not Imgproxy's global configuration default. |
| 🧩 Host-owned | Plug, router, or web-server configuration can provide this behavior outside ImagePipe. |
| 🚫 Rejected | Recognized or intentionally documented as unsupported, returning an error before side effects. |
| ⭕ Missing | Not implemented in the current parser/plan/runtime surface. |
| 🛑 Out of scope | Excluded from ImagePipe's library surface or delegated to host/runtime ownership. |

## Configuration options

ImagePipe doesn't read `IMGPROXY_*` environment variables. Variable markers show
whether ImagePipe has a matching or related `ImagePipe.Plug.init/1` option, source
adapter option, cache adapter option, or runtime option.

This section compares ImagePipe with imgproxy's configuration documentation
(`configuration/options.mdx`) and its config loaders (`*/config.go`) in
imgproxy's upstream repository.

### URL signature keys and trusted signatures

`imgproxy: [signature: [keys: [...], salts: [...], signature_size: n, trusted_signatures: [...]]]`.
ImagePipe expects already-split lists, not comma-separated environment strings.

- ✅ `IMGPROXY_KEY`
- ✅ `IMGPROXY_SALT`
- ✅ `IMGPROXY_SIGNATURE_SIZE`
- ✅ `IMGPROXY_TRUSTED_SIGNATURES`

### Server listener and connection limits

ImagePipe is a Plug. Bandit, Cowboy, Phoenix Endpoint, or another host server
owns socket binding, network family, and connection limits.

- 🧩 `IMGPROXY_BIND`
- 🧩 `IMGPROXY_NETWORK`
- 🧩 `IMGPROXY_MAX_CLIENTS`

### Request and response server timeouts

The host web server owns incoming request reads, response writes, and keep-alive
behavior. ImagePipe source adapters have separate fetch timeout options.

- 🧩 `IMGPROXY_READ_REQUEST_TIMEOUT`
- 🧩 `IMGPROXY_WRITE_RESPONSE_TIMEOUT`
- 🧩 `IMGPROXY_KEEP_ALIVE_TIMEOUT`

### Whole-request processing timeout

ImagePipe has source fetch and body-size limits, but no Imgproxy-style timeout
around the whole image request. A host can wrap the Plug, but ImagePipe doesn't
expose this as config.

- ⭕ `IMGPROXY_TIMEOUT`

### Authorization header secret

A host Plug or Phoenix pipeline can enforce `Authorization: Bearer ...` before
ImagePipe runs. ImagePipe itself doesn't check this header.

- 🧩 `IMGPROXY_SECRET`

### CORS response headers

A host Plug can add CORS headers around ImagePipe responses. ImagePipe doesn't
expose a CORS option.

- 🧩 `IMGPROXY_ALLOW_ORIGIN`

### Routing prefix

The router decides where ImagePipe mounts. ImagePipe parses the path segments it
receives after routing.

- 🧩 `IMGPROXY_PATH_PREFIX`

### Health check endpoint

The host app should expose health endpoints outside image processing routes.
ImagePipe doesn't include a health-check Plug.

- 🧩 `IMGPROXY_HEALTH_CHECK_PATH`
- 🧩 `IMGPROXY_HEALTH_CHECK_MESSAGE`

### Processing worker pool and request queue

ImagePipe doesn't expose an ImagePipe-owned worker pool or bounded request
queue. Host-level concurrency controls can protect the application, but they
aren't imgproxy-compatible configuration options.

- ⭕ `IMGPROXY_WORKERS`
- ⭕ `IMGPROXY_REQUESTS_QUEUE_SIZE`

### Source download request settings

`ImagePipe.Source.HTTP` supports `max_redirects`, `req_options`, and Req
timeout options. It doesn't provide Imgproxy's cookie forwarding,
request-header passthrough list, or SSL-verification environment switch.

- ✅ `IMGPROXY_DOWNLOAD_TIMEOUT`
- ✅ `IMGPROXY_MAX_REDIRECTS`
- ✅ `IMGPROXY_USER_AGENT`
- ⭕ `IMGPROXY_IGNORE_SSL_VERIFICATION`
- ✅ `IMGPROXY_CUSTOM_REQUEST_HEADERS`
- ⭕ `IMGPROXY_REQUEST_HEADERS_PASSTHROUGH`
- ⭕ `IMGPROXY_COOKIE_PASSTHROUGH`
- ⭕ `IMGPROXY_COOKIE_BASE_URL`
- ⭕ `IMGPROXY_COOKIE_PASSTHROUGH_ALL`

### Source URL rules and private-address policy

HTTP sources use `allowed_hosts`. This is stricter and simpler than Imgproxy's
source-prefix glob rules and doesn't expose IP-class switches.

- ⚠️ `IMGPROXY_ALLOWED_SOURCES`
- ⭕ `IMGPROXY_ALLOW_LOOPBACK_SOURCE_ADDRESSES`
- ⭕ `IMGPROXY_ALLOW_LINK_LOCAL_SOURCE_ADDRESSES`
- ⭕ `IMGPROXY_ALLOW_PRIVATE_SOURCE_ADDRESSES`

### Local filesystem sources

Configure `sources: [path: {ImagePipe.Source.File, root: ..., root_id: ...}]`.
`root` is the local filesystem root. `root_id` gives cache keys a deterministic
source identity without storing the absolute path.

- ✅ `IMGPROXY_LOCAL_FILESYSTEM_ROOT`

### Non-HTTP source query separator

ImagePipe parses `?` for HTTP, HTTPS, and S3 plain sources. ImagePipe rejects
local/path source queries.

- ⭕ `IMGPROXY_SOURCE_URL_QUERY_SEPARATOR`

### S3 image sources

`ImagePipe.Source.S3` supports `s3://bucket/key` sources with configured
`region`, `endpoint`, credentials, per-bucket overrides, and a path-style
request URL. It doesn't provide Imgproxy's enable flag, denied-bucket list,
assume-role environment variables, or decryption client.

- ⚠️ `IMGPROXY_USE_S3`
- ✅ `IMGPROXY_S3_REGION`
- ✅ `IMGPROXY_S3_ENDPOINT`
- ✅ `IMGPROXY_S3_ENDPOINT_USE_PATH_STYLE`
- ⭕ `IMGPROXY_S3_USE_DECRYPTION_CLIENT`
- ⭕ `IMGPROXY_S3_ASSUME_ROLE_ARN`
- ⭕ `IMGPROXY_S3_ASSUME_ROLE_EXTERNAL_ID`
- ✅ `IMGPROXY_S3_ALLOWED_BUCKETS`
- ⭕ `IMGPROXY_S3_DENIED_BUCKETS`

### GCS, Azure Blob Storage, and Swift image sources

ImagePipe has no built-in GCS, Azure Blob Storage, or Swift source adapters.
Custom `imgproxy: [source_schemes: ...]` translators can map more schemes to
application-owned source adapters.

- ⭕ `IMGPROXY_USE_GCS`
- ⭕ `IMGPROXY_GCS_*`
- ⭕ `IMGPROXY_USE_ABS`
- ⭕ `IMGPROXY_ABS_*`
- ⭕ `IMGPROXY_USE_SWIFT`
- ⭕ `IMGPROXY_SWIFT_*`

### Encoded sources, encrypted sources, and URL rewriting

ImagePipe supports Base64 encoded source URLs. It also supports encrypted source
URLs when callers configure `source_url_encryption_key` through
`ImagePipe.Plug.init/1`. Direct `ImagePipe.Parser.Imgproxy.parse/2` callers should
pass `imgproxy: ImagePipe.Parser.Imgproxy.validate_options!(...)`.

- ✅ Base64 encoded source URLs
- ✅ Encrypted source URLs
- ✅ `IMGPROXY_BASE64_URL_INCLUDES_FILENAME`
- ⭕ `IMGPROXY_BASE_URL`
- ⭕ `IMGPROXY_URL_REPLACEMENTS`

ImagePipe supports encoded source syntax and encoded `.extension` output
suffixes. With `base64_url_includes_filename: true`, it discards the final
encoded-source segment before decoding Base64 or decrypting `/enc/` sources.
This matches imgproxy's SEO filename mode. Base URL prefixing and URL
replacements are separate source rewriting features and aren't implemented.

### Processing argument separator and allowed option list

The compatibility parser uses `:` as the argument separator, accepts its
implemented option set, rejects unsupported security override URL options, and
has no configured pipeline-count limit.

- ⭕ `IMGPROXY_ARGUMENTS_SEPARATOR`
- ⭕ `IMGPROXY_ALLOWED_PROCESSING_OPTIONS`
- 🚫 `IMGPROXY_ALLOW_SECURITY_OPTIONS`
- ⭕ `IMGPROXY_MAX_CHAINED_PIPELINES`

### Preset definitions

Configure preset definitions with `imgproxy: [presets: %{"name" => "w:100"}]`.
ImagePipe validates a map of preset names to option strings during
`ImagePipe.Plug.init/1`.

- ✅ `IMGPROXY_PRESETS`

### Preset loading and preset-only modes

ImagePipe has no environment/file loader, presets-only mode, or info endpoint.

- ⭕ `IMGPROXY_PRESETS_SEPARATOR`
- ⭕ `IMGPROXY_PRESETS_PATH`
- ⭕ `IMGPROXY_ONLY_PRESETS`
- ⭕ `IMGPROXY_INFO_PRESETS`
- ⭕ `IMGPROXY_INFO_PRESETS_PATH`
- ⭕ `IMGPROXY_INFO_ONLY_PRESETS`

### Output format detection

Automatic output negotiation supports AVIF and WebP with `auto_avif` and
`auto_webp` options and emits `Vary: Accept`. It doesn't support JPEG XL,
enforced replacement of explicit formats, or Imgproxy's preferred-format
fallback list.

ImagePipe probes libvips AVIF/WebP write support at boot. Automatic negotiation
filters out formats the build cannot write; a modern source format the client did
not accept transcodes to raster (PNG/JPEG by alpha). An explicit `format` the
build cannot write is rejected with `501` before source fetch.

- ✅ `IMGPROXY_AUTO_WEBP`
- ✅ `IMGPROXY_ENABLE_WEBP_DETECTION`
- ✅ `IMGPROXY_AUTO_AVIF`
- ✅ `IMGPROXY_ENABLE_AVIF_DETECTION`
- ⭕ `IMGPROXY_AUTO_JXL`
- ⭕ `IMGPROXY_ENFORCE_WEBP`
- ⭕ `IMGPROXY_ENFORCE_AVIF`
- ⭕ `IMGPROXY_ENFORCE_JXL`
- ⭕ `IMGPROXY_PREFERRED_FORMATS`

### Client Hints defaults

ImagePipe doesn't derive default width or DPR from `Width` or `DPR` request
headers.

- ⭕ `IMGPROXY_ENABLE_CLIENT_HINTS`

### Default output quality

ImagePipe supports URL `quality`/`q` and `format_quality`/`fq`. It has no
Imgproxy-style global quality default or format-quality config.

- 🔗 `IMGPROXY_QUALITY`
- 🔗 `IMGPROXY_FORMAT_QUALITY`

### Advanced encoder options

ImagePipe passes only an explicit quality value to the encoder today. It
doesn't expose codec-specific knobs, byte-target search, `autoquality`, or JPEG
XL output.

- ⭕ `IMGPROXY_JPEG_PROGRESSIVE`
- ⭕ `IMGPROXY_JPEG_*`
- ⭕ `IMGPROXY_PNG_*`
- ⭕ `IMGPROXY_WEBP_*`
- ⭕ `IMGPROXY_AVIF_*`
- ⭕ `IMGPROXY_JXL_*`
- ⭕ `IMGPROXY_AUTOQUALITY_*`

### Metadata, color profile, HDR, and default autorotation policy

ImagePipe supports URL `auto_rotate` and the matching parser config default:
`imgproxy: [auto_rotate: true]`, which is also the default. URL `strip_metadata`,
`keep_copyright`, and `strip_color_profile` are supported with parser-owned
defaults and per-request URL overrides. HDR preservation and thumbnail-source
selection aren't configurable.

URL `auto_rotate`/`ar` resolves as request-scoped EXIF decode policy. If the URL
contains more than one `ar`, the last value in path order wins. When the
resolved policy is `true`, ImagePipe represents it as one `AutoOrient` operation
at the start of the first produced pipeline. Cache keys, ETags, and transform
execution then use the normal canonical plan machinery.

- ✅ `IMGPROXY_STRIP_METADATA` — Parser config default: `imgproxy: [strip_metadata: true]`. URL override: `sm:0` disables. Strips EXIF, XMP, and IPTC at encode time via `ImagePipe.Plan.Output` metadata policy.
- ✅ `IMGPROXY_KEEP_COPYRIGHT` — Parser config default: `imgproxy: [keep_copyright: true]`. URL override: `kcr:0` disables. **Diverges from imgproxy**: preserves EXIF copyright/artist fields only; imgproxy retains full XMP/IPTC blobs. ImagePipe strips XMP/IPTC even when `kcr` is on (privacy-conservative).
- ⭕ `IMGPROXY_STRIP_METADATA_DPI`
- ✅ `IMGPROXY_STRIP_COLOR_PROFILE` — Parser config default: `imgproxy: [strip_color_profile: true]`. URL override: `scp:0` disables. Implemented as a `NormalizeColorProfile` transform operation (ICC-aware sRGB conversion) positioned after geometry and before effects; the embedded profile header is dropped at encode. **Diverges from imgproxy**: imgproxy color-manages every image into a working space regardless of `scp`; ImagePipe only converts when `scp` is on (tracked in issue #124). With `scp:0` plus a tone effect on a wide-gamut source, effects run in the source profile space.
- ⭕ `IMGPROXY_COLOR_PROFILES_DIR`
- ⭕ `IMGPROXY_PRESERVE_HDR`
- ✅ `IMGPROXY_AUTO_ROTATE`
- ⭕ `IMGPROXY_ENFORCE_THUMBNAIL`

### Input and output safety limits

Top-level `max_body_bytes` caps fetched source bodies and defaults to
`10_000_000` bytes. Cache adapter `max_body_bytes` still caps encoded response
staging for adapters that configure it. ImagePipe uses `max_input_pixels` for
decoded input size and `max_result_width`, `max_result_height`, and
`max_result_pixels` for final static result size. `max_input_pixels` remains the
hard image-bomb gate (a `413` error on oversize decoded input), while the
`max_result_*` caps now **downscale the served result to fit** rather than
erroring — imgproxy `limitScale` parity (#165). It doesn't expose Imgproxy's
animation frame limits or SVG and PNG-specific policy.

ImagePipe realizes both the host `max_result_*` caps and the chosen output
encoder's hard per-dimension limit — WebP 16383, AVIF 16384 (JPEG 65535, PNG
effectively unbounded) — through the same `Output.Clamp` seam, uniformly
downscaling and serving rather than failing to encode. The encoder limit mirrors
imgproxy's internal `fixSize` step (`processing/fix_size.go`) and the host caps
mirror `limitScale`; it emits an `[:output, :clamp]`
telemetry event ([docs/telemetry.md](telemetry.md)). The encoder backstop has no
configurable knob, so it has no `IMGPROXY_*` row; the clamp triggers whenever the
realized result exceeds the tighter of the host caps and the encoder limit —
commonly the host cap (default 8192 per axis), which is below the encoder limits.

- ✅ `IMGPROXY_MAX_SRC_RESOLUTION`
- ✅ `IMGPROXY_MAX_SRC_FILE_SIZE`
- ⭕ `IMGPROXY_MAX_ANIMATION_FRAMES`
- ⭕ `IMGPROXY_MAX_ANIMATION_FRAME_RESOLUTION`
- ⭕ `IMGPROXY_MAX_RESULT_DIMENSION`
- ⭕ `IMGPROXY_MAX_SVG_CHECK_BYTES`
- ⭕ `IMGPROXY_PNG_UNLIMITED`
- ⭕ `IMGPROXY_SVG_UNLIMITED`
- ⭕ `IMGPROXY_SANITIZE_SVG`

### Cache storage

ImagePipe supports cache adapters through `cache: {Module, opts}`.
`ImagePipe.Cache.FileSystem` supports `root` and `path_prefix`. Shared cache
options support `key_headers`, `key_cookies`, and `max_body_bytes`. ImagePipe
has no built-in cloud cache adapters.

- ✅ `IMGPROXY_CACHE_USE`
- ✅ `IMGPROXY_CACHE_FS_ROOT`
- ✅ `IMGPROXY_CACHE_PATH_PREFIX`
- ⭕ `IMGPROXY_CACHE_BUCKET`
- ✅ `IMGPROXY_CACHE_KEY_HEADERS`
- ✅ `IMGPROXY_CACHE_KEY_COOKIES`
- ⭕ `IMGPROXY_CACHE_REPORT_ERRORS`
- ⭕ `IMGPROXY_CACHE_S3_*`
- ⭕ `IMGPROXY_CACHE_GCS_*`
- ⭕ `IMGPROXY_CACHE_ABS_*`
- ⭕ `IMGPROXY_CACHE_SWIFT_*`

### Response headers, cache headers, and default attachment disposition

ImagePipe supports URL `return_attachment`/`att` per request. It doesn't expose
Imgproxy's global response-header, ETag/Last-Modified, TTL, canonical-link,
debug-header, or default attachment settings. Host Plugs can add fixed response
headers outside ImagePipe.

- ⭕ `IMGPROXY_TTL`
- ⭕ `IMGPROXY_CACHE_CONTROL_PASSTHROUGH`
- ⭕ `IMGPROXY_SET_CANONICAL_HEADER`
- ⭕ `IMGPROXY_USE_ETAG`
- ⭕ `IMGPROXY_ETAG_BUSTER`
- ⭕ `IMGPROXY_USE_LAST_MODIFIED`
- ⭕ `IMGPROXY_LAST_MODIFIED_BUSTER`
- 🧩 `IMGPROXY_CUSTOM_RESPONSE_HEADERS`
- ⭕ `IMGPROXY_RESPONSE_HEADERS_PASSTHROUGH`
- 🔗 `IMGPROXY_RETURN_ATTACHMENT`
- ⭕ `IMGPROXY_ENABLE_DEBUG_HEADERS`
- ⭕ `IMGPROXY_SERVER_NAME`

### Fallback image

ImagePipe returns source and processing errors through its response sender. It
doesn't substitute a fallback image.

- ⭕ `IMGPROXY_FALLBACK_IMAGE_DATA`
- ⭕ `IMGPROXY_FALLBACK_IMAGE_PATH`
- ⭕ `IMGPROXY_FALLBACK_IMAGE_URL`
- ⭕ `IMGPROXY_FALLBACK_IMAGE_HTTP_CODE`
- ⭕ `IMGPROXY_FALLBACK_IMAGE_TTL`
- ⭕ `IMGPROXY_FALLBACK_IMAGE_PREPROCESS_URL`
- ⭕ `IMGPROXY_FALLBACK_IMAGES_CACHE_SIZE`

### Watermark defaults and custom watermark cache

ImagePipe doesn't model watermark processing.

- ⭕ `IMGPROXY_WATERMARK_DATA`
- ⭕ `IMGPROXY_WATERMARK_PATH`
- ⭕ `IMGPROXY_WATERMARK_URL`
- ⭕ `IMGPROXY_WATERMARK_OPACITY`
- ⭕ `IMGPROXY_WATERMARK_PREPROCESS_URL`
- ⭕ `IMGPROXY_WATERMARKS_CACHE_SIZE`

### SVG rendering and PDF/RAW handling

ImagePipe has no Imgproxy-compatible SVG render policy, PDF page policy, or RAW
source support.

- ⭕ `IMGPROXY_ALWAYS_RASTERIZE_SVG`
- ⭕ `IMGPROXY_SVG_FIX_UNSUPPORTED`
- ⭕ `IMGPROXY_PDF_NO_BACKGROUND`
- ⭕ `IMGPROXY_ENABLE_RAW_FORMATS`

### Smart crop, object detection, classification, and best-format models

ImagePipe supports object-detection gravity: `g:obj:face` / `c:W:H:obj:face`
(single `face` class), multi-class `g:obj:%c1:…:%cN`, and bare `g:obj` /
`g:obj:all` (all detected objects). All forms fall back to libvips attention
smart crop when the detector is unavailable. This graceful fallback is the
default; a host can instead opt into strict mode (`detector_required: true`),
which **rejects** a `g:obj:face` (or `g:obj:car`, etc.) request with a 422
(before any source fetch or cache access) when the relevant detector child is
unavailable rather than falling back — see
[content-aware-gravity.md](content-aware-gravity.md). Unknown classes are
dropped silently (best-effort). Face-assist `g:sm` is never hard-rejected.
Enabling ML gravity requires the host to add **both** `image_vision` **and** its
ONNX backend `ortex` (a Rust runtime) — see
[content-aware-gravity.md](content-aware-gravity.md) for the full host setup,
the `detector` / `detector_required` options, warmup, and custom detectors. None
of imgproxy's object-detection or smart-crop *configuration* knobs are read; they
are not blanket-missing now that part of the surface ships, so the relevant
variables are broken out below.

**Model and threshold divergence.** imgproxy uses host-configured YOLO models
with tunable confidence/NMS thresholds and a configurable gravity mode. ImagePipe
uses `image_vision`'s YuNet face model (fixed thresholds, ~340 KB) for face
detection and RT-DETR (~175 MB) for COCO-80 object detection. Detected boxes and
resulting crops are compatible in intent but are not bit-identical to imgproxy.
The RT-DETR model must be pre-fetched with `mix image_vision.download_models
--detect` (unlike YuNet, it does not auto-download on first use).

- ⭕ `IMGPROXY_OBJECT_DETECTION_GRAVITY_MODE` — imgproxy defaults to
  `max_score_area` (highest-scoring detected region). ImagePipe instead uses an
  area-weighted centroid of all detected regions, so the chosen focus point
  diverges from imgproxy's gravity mode.
- ⭕ `IMGPROXY_OBJECT_DETECTION_FALLBACK_TO_SMART_CROP` — by default ImagePipe
  falls back to libvips attention smart crop when no object is detected or the
  detector is unavailable. The imgproxy variable isn't read, but the fallback is
  not unconditional: a host can opt into strict mode (`detector_required: true`),
  which **rejects** a `g:obj:…` request with a 422 (before any source fetch or
  cache access) when the relevant detector is unavailable instead of falling back
  — see [content-aware-gravity.md](content-aware-gravity.md). Face-assist `g:sm`
  always falls back and is never hard-rejected.
- ⭕ `IMGPROXY_OBJECT_DETECTION_*` confidence and NMS thresholds — ImagePipe uses
  fixed detection-confidence and non-max-suppression thresholds for both the YuNet
  and RT-DETR models; they are not exposed as configuration.
- ✅ `IMGPROXY_SMART_CROP_FACE_DETECTION` — Modeled as the imgproxy-parser option
  `smart_crop_face_detection`; when enabled, `g:sm` blends the libvips attention
  point with detected faces (weight ~0.7). The attention⊕face combination is
  ImagePipe's approximation — imgproxy's internal combination is unspecified.
- ⭕ `IMGPROXY_SMART_CROP_ADVANCED*` — No advanced/object-aware smart-crop tuning
  surface; ImagePipe's smart crop is the libvips attention heuristic only.
- ⭕ `IMGPROXY_SMART_CROP_*` (other) — No other smart-crop configuration is read.
- ⭕ `IMGPROXY_OBJECT_DETECTION_*` (other) — No other object-detection
  configuration (model paths, class allow-lists) is read. Per-class weights are
  supplied per-request via the `objw` URL option.
- ⭕ `IMGPROXY_CLASSIFICATION_*`
- ⭕ `IMGPROXY_BEST_FORMAT_*`

### Video thumbnails

ImagePipe currently treats video processing as out of scope.

- 🛑 `IMGPROXY_ENABLE_VIDEO_THUMBNAILS`
- 🛑 `IMGPROXY_VIDEO_THUMBNAIL_*`

### Monitoring, error reporting, and logs

ImagePipe emits telemetry events. Host applications attach metrics, tracing,
logging, and external error reporting integrations.

- 🧩 `IMGPROXY_PROMETHEUS_*`
- 🧩 `IMGPROXY_DATADOG_*`
- 🧩 `IMGPROXY_OPEN_TELEMETRY_*`
- 🧩 `IMGPROXY_CLOUD_WATCH_*`
- 🧩 `IMGPROXY_NEW_RELIC_*`
- 🧩 `IMGPROXY_BUGSNAG_*`
- 🧩 `IMGPROXY_HONEYBADGER_*`
- 🧩 `IMGPROXY_SENTRY_*`
- 🧩 `IMGPROXY_AIRBRAKE_*`
- 🧩 `IMGPROXY_LOG_*`
- 🧩 `IMGPROXY_SYSLOG_*`

### Memory, libvips, Docker, and licensing knobs

ImagePipe doesn't own the OS allocator, libvips process-wide tuning, container
entrypoint, license checks, or deprecation handling.

- 🛑 `IMGPROXY_DOWNLOAD_BUFFER_SIZE`
- 🛑 `IMGPROXY_FREE_MEMORY_INTERVAL`
- 🛑 `IMGPROXY_BUFFER_POOL_CALIBRATION_THRESHOLD`
- 🛑 `IMGPROXY_MALLOC`
- 🛑 `IMGPROXY_VIPS_CACHE_TRACE`
- 🛑 `IMGPROXY_VIPS_LEAK_CHECK`
- 🛑 `IMGPROXY_LICENSE_KEY`
- 🛑 `IMGPROXY_LICENSE_DEVELOPMENT_MODE`
- 🛑 `IMGPROXY_FAIL_ON_DEPRECATION`

## URL shape, source, and security

| Imgproxy feature | Status | Notes |
| --- | --- | --- |
| Required signature path segment | Supported | Without signing, ImagePipe accepts `_` and `unsafe`. With signing configured, it accepts HMAC and exact trusted signatures. Trusted-only config accepts only exact trusted signatures. This behavior is narrower than upstream unsigned behavior. |
| HMAC URL signatures | Supported | Imgproxy parser verifies raw/unpadded Base64URL HMAC-SHA256 signatures with hex key/salt pairs, optional truncation, rotation pairs, exact trusted signatures, and Imgproxy-compatible `fixPath` before verification. Signature failures return 403. |
| Plain source URLs via `/plain/` | Supported | ImagePipe translates the value into configured source adapters for local paths, HTTP and HTTPS URLs, S3-compatible object sources, and configured custom schemes. |
| Plain source `@extension` | Supported | Requests explicit output format and bypasses `Accept` negotiation. It doesn't declare source format. |
| Base64 encoded source URL | Supported | ImagePipe supports Imgproxy encoded source syntax, `.extension` output suffixes, and opt-in SEO filename suffix mode. |
| Encrypted `/enc/` source URL | Supported | Requires `source_url_encryption_key`. ImagePipe accepts `base64url(iv <> aes-cbc-pkcs7(source_url))`, optional `.extension`, chunked encrypted segments, and opt-in SEO filename suffix mode. |
| AES-CBC source URL encryption helpers | Supported | `ImagePipe.Parser.Imgproxy.encrypt_source_url/3` returns the segment used after `/enc/`. The helper doesn't build full paths, output suffixes, or signatures. |
| `IMGPROXY_BASE_URL` | Missing | ImagePipe doesn't prepend a configured base URL to decoded, decrypted, or plain source strings. Use ImagePipe source configuration instead. |
| `IMGPROXY_URL_REPLACEMENTS` | Missing | ImagePipe doesn't rewrite decoded, decrypted, or plain source strings before source translation. |
| Custom argument separator | Missing | Parser currently uses `:`. |
| Processing option order independence | Supported | URL option order doesn't define transform order. |
| Pipeline separator `-` | Supported | Separates non-empty pipeline groups. |

### Source input formats

ImagePipe detects source family after libvips decodes the input. Accepted source
families in this slice are JPEG, PNG, WebP, AVIF, non-AVIF HEIF/HEIC, TIFF,
JPEG 2000, and JPEG XL when the deployed libvips build can read them.

This slice doesn't support SVG, GIF, ICO, BMP, PDF, PSD, RAW, or video inputs.
ImagePipe rejects SVG after decode identifies an SVG loader and before
transforms or output encoding.

## Resize, geometry, and orientation

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `resize` | `rs` | Supported | Includes optional resize-tail `enlarge`, `extend`, and extend gravity. |
| `size` | `s` | Supported | Same field mapping as Imgproxy size meta-option. |
| `resizing_type` | `rt` | Supported | `fit`, `fill`, `fill-down`, `force`, and `auto`. |
| `resizing_algorithm` | `ra` | Missing | Pro algorithm selection. No algorithm selection in plan or transform execution. |
| `width` | `w` | Supported | Non-negative integer. `0` means auto. |
| `height` | `h` | Supported | Non-negative integer. `0` means auto. |
| `min-width` | `mw` | Supported | Non-negative integer. |
| `min-height` | `mh` | Supported | Non-negative integer. |
| `zoom` | `z` | Supported | Single value or separate x/y factors. |
| `dpr` | | Supported | Affects resize sizing and cache key data. |
| `enlarge` | `el` | Supported | boolean. |
| `extend` | `ex` | Supported | Canvas extension with anchor gravity and offsets. |
| `extend_aspect_ratio` | `extend_ar`, `exar` | Supported | boolean extend plus gravity. Extends the canvas to the requested resize aspect ratio. `fp` extend-gravity isn't supported (matches `extend`). No-op when a resize dimension is auto or zero. |
| `gravity` anchors | `g` | Supported | `ce`, `no`, `so`, `ea`, `we`, `noea`, `nowe`, `soea`, `sowe`. |
| `gravity:fp` | `g:fp` | Supported | Focal point coordinates from `0.0` to `1.0`. |
| `gravity:sm` | `g:sm` | Supported | Smart gravity via libvips attention smart crop (`VIPS_INTERESTING_ATTENTION`). |
| `gravity:obj:face` | `g:obj:face` | Supported | Single `face` class via optional `image_vision` YuNet face detection; falls back to libvips attention when the detector is unavailable. |
| `gravity:obj` / `g:obj:all` | | Supported | All detected objects — union of face (YuNet) and COCO-80 object (RT-DETR) detectors; falls back to libvips attention when the detector is unavailable. |
| `gravity:obj:%c1:…:%cN` | | Supported | Multi-class object gravity using the COCO-80 vocabulary (underscore spelling, e.g. `g:obj:car:traffic_light`). Unknown classes are silently dropped (best-effort). Class-aware cache identity: only the detector children routed by the requested class set contribute to the cache key. |
| `gravity:objw` | | Supported | Pro per-class object-detection gravity weights. `g:objw:%c1:%w1:…:%cN:%wN` — positional class/weight pairs, weights are positive decimals (`≤ 0` rejected). Named classes form the detection spec (filter), exactly like `obj`; `all` is the pseudo-class that broadens detection to every class and sets the baseline default weight (e.g. `objw:all:2:face:3` = "detect everything, weight 2 by default, faces weight 3"). `objw:face:3` filters to faces (spec `["face"]`); `objw:all:1:face:3` detects all with face boost (spec `:all`) — they are NOT equivalent. Supported in both `g:` and `c:W:H:` forms. Falls back to libvips attention smart crop when the detector is unavailable. |
| `objects_position` | `obj_pos`, `op` | Missing | Pro object-detection positioning. |
| `crop` | `c` | Supported | Absolute, relative, or full-axis dimensions. Supports anchor, focal-point, smart gravity (`c:W:H:sm`), object gravity (`c:W:H:obj:face`, `c:W:H:obj:car:dog`, `c:W:H:obj`, `c:W:H:obj:all`), and per-class weighted object gravity (`c:W:H:objw:%c1:%w1:…`); smart gravity runs libvips attention smart crop, and object gravity uses optional `image_vision` detection with attention fallback. |
| `crop_aspect_ratio` | `crop_ar`, `car` | Supported | Pro crop-area aspect-ratio correction. `aspect_ratio` zero is a no-op. `enlarge` grows the area then clamps to image bounds; default reduces. Corrects size only, not gravity. Wired through gravity crops. |
| `trim` | `t` | Missing | Requires full-image memory behavior and trim operation. |
| `padding` | `pd` | Supported | CSS-style shorthand, sparse repeated options, effective DPR scaling, and `padding:` no-op compatibility. |
| `auto_rotate` | `ar` | Supported | Omitted argument enables auto-orient; boolean form supported. URL `ar` overrides `imgproxy: [auto_rotate: ...]` request-wide, with last value in path order winning. |
| `rotate` | `rot` | Supported | Right-angle multiples normalize to `0`, `90`, `180`, or `270`. |
| `flip` | `fl` | Supported | No arguments means both axes. Supports one or two booleans. |

## Background, effects, and overlays

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `background` | `bg` | Supported | RGB decimal and 3/6 digit hex colors. `background:` clears previous background color and alpha. |
| `background_alpha` | `bga` | Supported | Applies an alpha channel to the current or next background color. Without an explicit background color, uses Imgproxy's default black background. |
| `adjust` | `a` | Missing | Pro meta-option for brightness, contrast, and saturation. Use the individual options below instead. |
| `brightness` | `br` | Supported | Number from `-100` to `100`. `0` parses as an Imgproxy-compatible no-op. Runs after pixelate. |
| `contrast` | `co` | Supported | Number from `-100` to `100`. `0` parses as an Imgproxy-compatible no-op. Runs after brightness. |
| `saturation` | `sa` | Supported | Number from `-100` to `100`. `0` parses as an Imgproxy-compatible no-op. Runs after contrast. |
| `monochrome` | `mc` | Supported | Intensity from `0` to `1`, optional hex color, and `0` no-op behavior. |
| `duotone` | `dt` | Supported | Intensity from `0` to `1`, optional shadow/highlight hex colors, and `0` no-op behavior. |
| `blur` | `bl` | Supported | Non-negative sigma value. `0` parses as an Imgproxy-compatible no-op. Runs before canvas extension and background flattening. |
| `sharpen` | `sh` | Supported | Non-negative sigma value. `0` parses as an Imgproxy-compatible no-op. Runs after blur when both are present. |
| `pixelate` | `pix` | Supported | Non-negative integer size. `0` and `1` parse as Imgproxy-compatible no-ops. |
| `unsharp_masking` | `ush` | Missing | Pro advanced sharpening controls. |
| `blur_areas` | `ba` | Missing | Pro area blur. |
| `blur_detections` | `bd` | Missing | Pro object-detection blur. |
| `draw_detections` | `dd` | Missing | Pro object-detection debug overlay. |
| `crop_objects` | `co` | Missing | Pro object-detection crop. **Alias collision**: imgproxy aliases `co` to both `contrast` and `crop_objects`; ImagePipe binds `co` → `contrast` only, and `crop_objects` is out of scope. |
| `colorize` | `col` | Missing | Pro overlay effect. |
| `gradient` | `gr` | Missing | Pro gradient overlay. |
| `watermark` | `wm` | Missing | Base watermark semantics aren't modeled. |
| `watermark_url` | `wmu` | Missing | Pro custom watermark source. |
| `watermark_text` | `wmt` | Missing | Pro generated watermark image. |
| `watermark_size` | `wms` | Missing | Pro watermark sizing. |
| `watermark_rotate` | `wm_rot`, `wmr` | Missing | Pro watermark rotation. |
| `watermark_shadow` | `wmsh` | Missing | Pro watermark shadow. |
| `style` | `st` | Missing | Pro SVG-specific style injection. |

## Metadata, color, and source decoding

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `strip_metadata` | `sm` | Supported | Default on. Parser config: `imgproxy: [strip_metadata: true]`. URL override `sm:0` disables. Strips EXIF, XMP, and IPTC at encode time via `ImagePipe.Plan.Output` metadata policy. |
| `keep_copyright` | `kcr` | Supported | Default on. Parser config: `imgproxy: [keep_copyright: true]`. URL override `kcr:0` disables. **Diverges from imgproxy**: preserves EXIF copyright/artist fields only; imgproxy retains full XMP/IPTC blobs. ImagePipe strips XMP/IPTC even when `kcr` is on (privacy-conservative). |
| `dpi` | | Missing | Pro metadata rewrite. |
| `strip_color_profile` | `scp` | Supported | Default on. Parser config: `imgproxy: [strip_color_profile: true]`. URL override `scp:0` disables. Implemented as a `NormalizeColorProfile` transform operation (ICC-aware sRGB conversion) positioned after geometry and before effects; the embedded profile header is dropped at encode. **Diverges from imgproxy**: imgproxy color-manages every image regardless of `scp`; ImagePipe only converts when `scp` is on (tracked in issue #124). With `scp:0` plus a tone effect on a wide-gamut source, effects run in the source profile space. |
| `preserve_hdr` | `ph` | Missing | No HDR preservation toggle. |
| `color_profile` | `cp`, `icc` | Missing | Pro profile conversion/embedding. |
| `enforce_thumbnail` | `eth` | Missing | No embedded thumbnail decode selection. |
| `page` | `pg` | Missing | Pro paginated/animated source selection. |
| `pages` | `pgs` | Missing | Pro multi-page stacking. |
| `disable_animation` | `da` | Missing | Pro animation handling. |

## Output and encoding

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `quality` | `q` | Supported | `0` means configured default. Supports `1..100`. |
| `format_quality` | `fq` | Partial | One `<format>:<quality>` pair per option segment. Repeated segments merge. More than one pair in one segment isn't supported. |
| `autoquality` | `aq` | Missing | Pro multi-encode quality search. |
| `max_bytes` | `mb` | Missing | No iterative encode degradation. |
| `jpeg_options` | `jpgo` | Missing | Pro advanced JPEG encoder controls. |
| `png_options` | `pngo` | Missing | Pro advanced PNG encoder controls. |
| `webp_options` | `webpo` | Missing | Pro advanced WebP encoder controls. |
| `avif_options` | `avifo` | Missing | Pro advanced AVIF encoder controls. |
| `format` | `f`, `ext` | Partial | Supports `webp`, `avif`, `jpeg`, `jpg`, and `png`. Planning rejects parsed `best`. |
| Extension path suffix | | Partial | Plain sources use `@extension`; Base64 and encrypted sources use `.extension`. Both request explicit output format and bypass `Accept` negotiation. |
| Automatic output via `Accept` | | Supported | Omitted format negotiates explicit AVIF/WebP support and `image/*`; missing, empty, and global wildcard-only `Accept` values fall back to source output. Responses use `Vary: Accept`. |
| `best` output | | Rejected | Parsed as an output value, rejected by planning. |

## Video

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `video_thumbnail_second` | `vts` | Out of scope | Pro video source support. |
| `video_thumbnail_keyframes` | `vtk` | Out of scope | Pro video source support. |
| `video_thumbnail_tile` | `vtt` | Out of scope | Pro video sprite generation. |
| `video_thumbnail_animation` | `vta` | Out of scope | Pro video animation generation. |

## Fallback, raw, and request policy

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `fallback_image_url` | `fiu` | Missing | Pro fallback source behavior. |
| `skip_processing` | `skp` | Missing | No source-format raw pass-through path. |
| `raw` | | Missing | Documented as unsupported. It would alter request safety and streaming model. |
| `cachebuster` | `cb` | Supported | Participates in cache key data, not transforms. |
| `expires` | `exp` | Supported | Rejects expired requests before source/cache side effects. |
| `filename` | `fn` | Supported | Percent-decoded or URL-safe Base64 filename stem. |
| `return_attachment` | `att` | Supported | Controls `Content-Disposition` disposition. |
| `preset` | `pr` | Supported | Normal processing URLs support configured named presets, more than one name in one segment, `default` automatic expansion, nested presets with recursive re-entry skipped, and documented chained-pipeline merge semantics. |
| `hashsum` | `hs` | Missing | Pro source integrity check. |

## Security limit overrides

| Imgproxy option | Aliases | Status | Notes |
| --- | --- | --- | --- |
| `max_src_resolution` | `msr` | Missing | Security override; should require explicit opt-in if added. |
| `max_src_file_size` | `msfs` | Missing | Security override; should require explicit opt-in if added. |
| `max_animation_frames` | `maf` | Missing | Animation support isn't modeled. |
| `max_animation_frame_resolution` | `mafr` | Missing | Animation support isn't modeled. |
| `max_result_dimension` | `mrd` | Missing | Security override; should require explicit opt-in if added. |

## Presets

| Imgproxy feature | Status | Notes |
| --- | --- | --- |
| Named presets | Supported | Configured through `imgproxy: [presets: %{name => options}]`. Expanded while parsing normal processing URLs. |
| Repeated preset arguments | Supported | `pr:thumb:sharp` applies each named preset in order. |
| `default` preset | Supported | Applied before URL options on every normal processing request. URL fields can override fields in the same merged group. |
| Presets referencing presets | Supported | Presets may use `preset`/`pr`. ImagePipe skips recursive re-entry to match Imgproxy behavior. |
| Preset chained pipelines | Partial | Supports documented Pro merge semantics for preset values containing `-` when the referenced options are otherwise supported by ImagePipe. |
| Presets-only mode | Missing | Excluded from this slice. |
| Info endpoint presets | Missing | ImagePipe doesn't currently expose Imgproxy info endpoints. |
| Preset env/file loading | Missing | ImagePipe doesn't parse `IMGPROXY_PRESETS` strings or `IMGPROXY_PRESETS_PATH` files. Pass already-materialized presets through config instead. |
