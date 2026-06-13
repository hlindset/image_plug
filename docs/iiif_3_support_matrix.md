# IIIF Image API 3.0 support matrix

`ImagePipe.Parser.IIIF` targets **IIIF Image API 3.0, Level 2 conformance**. It is a compatibility *parser* that translates the IIIF positional request grammar `…/{identifier}/{region}/{size}/{rotation}/{quality}.{format}` (and `…/{identifier}/info.json`) into a product-neutral `ImagePipe.Plan`, then runs the same core transform/output pipeline as every other dialect. The IIIF processing order **Region → Size → Rotation → Quality (→ Format)** maps onto the fixed native pipeline order.

Spec: <https://iiif.io/api/image/3.0/> · Compliance: <https://iiif.io/api/image/3.0/compliance/> · Validator: <https://github.com/IIIF/image-validator>

## How to read this

Each row tracks one of three axes (same discipline as `docs/imgproxy_support_matrix.md`):

| Axis | Question | Where |
| --- | --- | --- |
| **Surface** | Do we parse the same URL grammar / config? | the grammar tables below |
| **Stage / order** | Do we run compatible processing stages in IIIF order? | "Processing order" + the shared native pipeline (`docs/imgproxy_support_matrix.md`) |
| **Behavioral / pixel** | Does a matching request produce conformant output? | the wire tests (`test/parser/iiif_wire_test.exs`) + the official `image-validator` gate + the "Diverges" notes |

Status legend: ✅ supported · ➖ deliberately deferred (an optional `extraFeature`) · ⚠️ supported with a documented divergence.

## Compliance level

We implement **Level 2**: all of Level 0/1 plus the Level-2-required `regionByPx`, `regionByPct`, `sizeByW`, `sizeByH`, `sizeByWh`, `sizeByConfinedWh`, `sizeByPct`, `rotationBy90s`, and the `color`/`gray`/`bitonal` qualities. A handful of `extraFeatures` are implemented beyond Level 2 (`regionSquare`, `sizeUpscaling`, `webp`/`avif` formats); the rest are deferred (see "Deferred extraFeatures").

## Region (→ crop op; `full` emits no op)

| Token | Feature | Status | Mapping / notes |
| --- | --- | --- | --- |
| `full` | — | ✅ | No crop operation. |
| `square` | `regionSquare` (extra) | ✅ | `Plan.Operation.CropGuided` with `aspect_ratio: {:ratio, 1, 1}`, centered (`{:anchor, :center, :center}`). The validator's `region_square` checks only that the result is square; centered is the chosen (recommended) placement. |
| `x,y,w,h` | `regionByPx` | ✅ | `Plan.Operation.CropRegion{x: {:px,x}, y: {:px,y}, width: {:px,w}, height: {:px,h}}`. Out-of-bounds is clipped to the image; a region wholly outside, or with `w`/`h` = 0, is a **400**. |
| `pct:x,y,w,h` | `regionByPct` | ✅ | `CropRegion` with `{:ratio, n, d}` coordinates; decimal percents become exact integer ratios (e.g. `10.5` → `{:ratio, 105, 1000}`). |

## Size (→ `Resize`)

A leading `^` enables upscaling. Without `^`, an explicit-size form that would upscale is a **400** (`enlargement: :reject`); `max` clamps (`:deny`); `^` forms allow (`:allow`). See "Status mapping" for the 400 path.

| Token | Feature | Status | Mapping / notes |
| --- | --- | --- | --- |
| `max` / `^max` | — | ✅ | `Resize{mode: :fit, width: :auto, height: :auto}`; `max` → `:deny` (never upscales), `^max` → `:allow`. Bounded by `maxWidth`/`maxHeight`/`maxArea` when configured. |
| `w,` | `sizeByW` | ✅ | `Resize{mode: :fit, width: {:px,w}, height: :auto, enlargement: :reject/:allow}`. |
| `,h` | `sizeByH` | ✅ | `Resize{mode: :fit, width: :auto, height: {:px,h}}`. |
| `w,h` | `sizeByWh` | ✅ | `Resize{mode: :stretch, …}` — **exact dimensions, may distort** (IIIF `w,h` is not aspect-preserving). |
| `!w,h` | `sizeByConfinedWh` | ✅ | `Resize{mode: :fit, …}` — fit within the box, preserve aspect. Upscale without `^` → **400** (`:reject`); a fit-*down* returns 200. |
| `pct:n` | `sizeByPct` | ✅ | `Resize{mode: :fit, zoom_x: n/100, zoom_y: n/100}`. The IIIF "`n` ≤ 100" rule is lifted under `^` (`^pct:200` is a valid upscale; bare `pct:200` is a 400). |
| `^…` | `sizeUpscaling` (extra) | ✅ | Any `^` form → `enlargement: :allow`. The pixel-verifying `size_up.py` is a Level-3 validator test (not run at the Level-2 gate); our own wire tests exercise `^` forms. |

## Rotation (→ `Rotate`)

| Token | Feature | Status | Notes |
| --- | --- | --- | --- |
| `0` | — | ✅ | No op. |
| `90` / `180` / `270` | `rotationBy90s` | ✅ | `Plan.Operation.Rotate{angle: …}`. Applied *after* the region crop (see "auto_rotate" below). |
| `!n` (mirroring), arbitrary angle | `mirroring`, `rotationArbitrary` (extra) | ➖ | Deferred. A non-90 multiple or `!`-prefixed rotation is a **400**. |

## Quality (→ `gray` op or no-op)

| Token | Feature | Status | Notes |
| --- | --- | --- | --- |
| `default` / `color` | — | ✅ | No op (full color). |
| `gray` | `gray` quality | ✅ | `Plan.Operation.Gray` — **true desaturation** via `Image.to_colorspace(:bw)` (luminance only), *not* a color tint (`Monochrome`). Preserves alpha for alpha-capable output formats. |
| `bitonal` | `bitonal` quality (Level 2 required) | ✅ | `Plan.Operation.Bitonal` — `:bw` colourspace + a `>= 128` threshold (each band → 0/255). The validator's `quality_bitonal` is a **Level-2** test (same level as `color`/`gray`), so it is required for the gate. |

> Note: `default`/`color`/`gray`/`bitonal` are all baseline at Level 2; we list `color`/`gray`/`bitonal` in `extraQualities` (harmless over-listing — the validator does not reject it).

## Format

| Token | Status | Output |
| --- | --- | --- |
| `jpg` | ✅ | `{:explicit, :jpeg}` (Level 2 required) |
| `png` | ✅ | `{:explicit, :png}` (Level 2 required) |
| `webp` | ✅ (extra) | `{:explicit, :webp}` |
| `avif` | ✅ (extra) | `{:explicit, :avif}` |
| `jp2` / `gif` / `tif` / `pdf` | ➖ | Deferred (extra). An unsupported but valid format token → **400** (the validator accepts `[400, 415, 503]`). |

## info.json

Served via the cross-dialect render mechanism (`render: {:custom, ImagePipe.Parser.IIIF.InfoRenderer, params}`; the source header is decoded but the transform pipeline never runs).

| Field | Status | Notes |
| --- | --- | --- |
| `@context`, `type` (`ImageService3`), `protocol`, `profile` (`"level2"`) | ✅ | Exact strings per the 3.0 spec; `info_json` validator-checked. |
| `id` | ✅ | Absolute base URI reconstructed from the request (`scheme://host[:port]/{mount}/{identifier}`), no spurious default-port suffix. |
| `width` / `height` | ✅ | **Display** dimensions (post-EXIF-orientation) via `ImagePipe.Plan.SourceInfo.display_dimensions/1` — a quarter-turn source (EXIF 5–8) reports swapped dims. |
| `maxWidth` / `maxHeight` / `maxArea` | ✅ | Emitted only when configured (omitted when nil — never `null`). |
| `extraQualities` / `extraFormats` / `extraFeatures` | ✅ | Reflect what is implemented; spelled per the IIIF feature registry. |
| **Content negotiation** | ✅ | `Accept: application/ld+json` → `Content-Type: application/ld+json;profile="…/context.json"` with `Vary: Accept`; otherwise `application/json`. Body is byte-identical (cache identity stays Accept-independent). Validator-checked by `jsonld`. |

## HTTP behavior

| Feature | Status | Notes |
| --- | --- | --- |
| `baseUriRedirect` | ✅ | `{identifier}` (bare) → **303** to `{identifier}/info.json`. Short-circuits before any source fetch (`{:redirect, 303, location}` parse outcome). |
| `cors` | ✅ | `Access-Control-Allow-Origin: *` on every IIIF response (image, info.json, redirect, errors) + `OPTIONS` preflight → 200, applied by the mount-level `ImagePipe.Parser.IIIF.CORS` plug (the parser's `parse/2` returns a tuple, not a conn, so CORS *must* be mount-level). |
| `jsonldMediaType` | ✅ | See info.json negotiation. |
| Canonical `Link` header (`rel="canonical"`) | ➖ | Optional (`may` per spec); not implemented. Computing the canonical-spelling URL and threading a per-request response header is deferred; the validator does not require it. |

## Status mapping (validator-checked)

| Case | Status | Where |
| --- | --- | --- |
| Malformed/unsupported region/size/rotation/quality/format token | **400** | parse → `handle_error/2` |
| Region `w`/`h` = 0; size computes to 0 | **400** | parse |
| Region wholly out of bounds; explicit-size upscale without `^` | **400** | runtime `{:transform_error, {:bad_request, _}}` → `Sender` (the minimal slice of the customizable error→status mechanism, [#267](https://github.com/hlindset/image_pipe/issues/267)) |
| Region partial overlap | **200** (clip) | runtime |
| Unknown identifier (resolver miss); `path_info` shape mismatch (incl. unescaped-slash `a/b`) | **404** | resolver / exact-segment-count dispatch |

## Identifier → Source

The opaque IIIF `{identifier}` is resolved by a host-configured `ImagePipe.Parser.IIIF.Resolver` behaviour (`resolve/2`). A `Resolver.Static` built-in maps identifiers to `Plan.Source` structs from a static map (opaque IDs, no source-structure leakage). A source-string resolver (URL-in-identifier) is deferred.

## Diverges / intentional notes

- **`auto_rotate` defaults `true`** (configurable via `iiif: [auto_rotate: …]`). IIIF region/size/rotation and the info.json dimensions are defined in the **displayed** (post-EXIF-orientation) coordinate system. This is the more correct behavior, not a divergence: an absolute-coordinate `CropRegion` is made display-correct by flushing the EXIF pending orientation *before* the crop (rescaling against the orientation-swapped `decode_shrink`); the IIIF rotation param folds into `pending_orientation` and is applied *after* the region crop. The validator reference image is orientation-1, so the gate is unaffected.
- **Upscale-without-`^` returns the spec-recommended 400** via the `{:bad_request, _}` transform reason. The *general*, host-customizable error→status mapping is tracked by [#267](https://github.com/hlindset/image_pipe/issues/267).
- **`gray` on a non-alpha output format (e.g. `gray.jpg`) with an alpha source flattens onto the background** (valid output) via the encoder's format-driven flatten ([#269](https://github.com/hlindset/image_pipe/pull/269)); `gray` preserves alpha for alpha-capable formats (`gray.png`/`gray.webp`/`gray.avif`).

## Deferred extraFeatures

All optional at every compliance level; tracked separately if a consumer needs them: arbitrary-angle rotation (`rotationArbitrary`), mirroring (`mirroring`, `!n`), and `jp2`/`gif`/`tif`/`pdf` output formats.

## Verification

- **Wire tests:** `test/parser/iiif_wire_test.exs` — real `ImagePipe.call/2` end-to-end (status, headers, `Vary`, CORS, decoded dimensions, gray pixel checks incl. the RGBA→JPEG flatten, info.json + ld+json negotiation, 303 redirect, the 400/404 status mapping).
- **Official validator gate:** the Python `image-validator` runs against a live IIIF endpoint serving the canonical `67352ccc-…` reference image via the Static resolver, at `--version=3.0 --level 2` (see `validator/`). The `--level 2` flag is mandatory — the tool defaults to Level 1 and would otherwise silently skip the Level-2 tests.
