# Design: cross-dialect non-image render mechanism + imgproxy info API (Phase 1)

Issue: [#252](https://github.com/hlindset/image_plug/issues/252) — IIIF Image API support, Phase 1.
Type: `type:design`. Target: imgproxy compatibility (first consumer); IIIF `info.json` is Phase 2.

## Problem

`ImagePipe.Parser.parse/2` only yields an `ImagePipe.Plan`, and the response path
only emits encoded image bytes. There is no way to return a non-image (JSON/text)
response. The first concrete consumer is **imgproxy's info API** (`/info`); the
second, later, is IIIF's `info.json` (Phase 2). A third, on the roadmap, is a
TwicPics-style `output=blurhash` / `output=lqip` representation of the **processed**
image, selected via the output/format parameter.

We need a mechanism that lets a dialect emit a non-image response while reusing the
existing request lifecycle (source-safety, decode, cache, ETag/conditional-GET,
telemetry) rather than forking a parallel path.

## Upstream ground truth (imgproxy)

**The `/info` endpoint is a Pro-only feature and is _not_ implemented in the OSS
imgproxy source** (no `/info` route in `imgproxy.go`; the docs mark it `((pro))`).
The only ground truth is the documentation
(`/Users/hlindset/src/imgproxy-docs/docs/usage/getting_info.mdx`) and the URL/
signature docs (`signing_url.mdx`). We match the **documented** contract.

### `/info` is mixed-depth within one response

A single `/info` response can combine fields of very different cost. The documented
fields, grouped by what they actually require:

| Cost tier | imgproxy info fields |
| --- | --- |
| header (lazy open, no pixels) | `format`, `mime_type`, `width`, `height`, `orientation`, `colorspace`, `bands`, `sample_format`, `alpha`, `pages_number` |
| header metadata blocks | `exif`, `iptc`, `xmp` |
| full pixel decode (+ detector/inference) | `detect_objects`, `classify`, `crop` (object gravity), `palette`, `average`, `dominant_colors`, `blurhash`, `thumb_hash`, `perceptual_hash` |
| entire raw byte stream | `size` (when no `Content-Length`), `hashsums` |

A request such as `format:1/dimensions:1/detect_objects:1/hashsums:sha256` needs all
four tiers merged into one JSON document. **Depth is the union of the enabled
fields' needs.** This is a property of the very first consumer, not a hypothetical.

The default-enabled fields are `size`, `format`, `dimensions`, `orientation`,
`exif`, `iptc`, `xmp`. Every pixel/stream-tier field is opt-in and default-OFF.

### URL grammar / signature (must-match)

From `getting_info.mdx` and `signing_url.mdx`:

```
/info/%signature/%info_options/plain/%source_url
/info/%signature/%info_options/%encoded_source_url
/info/%signature/%info_options/enc/%encrypted_source_url
```

- **`/info` is an UNSIGNED path prefix.** The HMAC covers
  `salt + "/" + info_options + "/" + source` — the leading `/info` is *not* part of
  the signed payload. The dispatcher must **peel `/info` first, then run the
  existing signature extract/verify on the remainder.** (ImagePipe's `Path.extract`
  treats segment 1 as the signature; feeding it an `/info/...` URL would mis-verify.)
- **Info URLs carry no output extension.** The reused source parser must not run the
  `.`-split output-extension logic, or `plain/http://x/a.jpg` mis-parses.
- **Info-options live _inside_ the signed path.** Even though Phase 1 ignores their
  *effect*, the options segment must still be parsed (and ignored), or a signature
  over an option-bearing URL won't verify.
- Source decoding (encoded / `plain` / `enc`) is otherwise identical to the
  processing endpoint and is reused unchanged.

## Design principle

The shared layer owns the **pipeline**, not the **schema**. Each dialect owns its
serializer. We do **not** model a unified info document: imgproxy info reports facts
about an image; IIIF `info.json` is a service-capability advertisement; TwicPics
blurhash is a representation of the processed image. These are semantically
different and stay isolated in their dialect renderers.

## Architecture: the terminal stage becomes a Renderer

Today the producer's terminal (`lib/image_pipe/request/source_session/producer.ex`
`prepare_first_chunk/1`, lines ~114–166) hardcodes the last stages as "encode an
image":

```
fetch_decode → process_decoded_source → resolve_output → clamp → materialize → encode_first_chunk → stream
```

Everything up to `fetch_decode` is representation-neutral; only the tail is
image-specific. We generalize the tail into a polymorphic **renderer**. The image
encoder becomes the *default* renderer. A non-image response is a different terminal
renderer on the **same** pipeline — so source-safety, decode, cache, ETag/
conditional-GET, and telemetry are reused, not duplicated.

Because imgproxy info is mixed-depth (a single response may need header + pixels +
detector + raw bytes), info routes through the **producer** — the place where
pixel/decode/stream work and disconnect-cancellation already live. A header-only
response is the degenerate case: the producer reads the header during decode, the
renderer serializes, and the heavy tail (process/materialize/encode) is skipped.
This avoids a split-and-merge between a "cheap synchronous" and a "heavy producer"
path.

### The `requires` contract (the load-bearing discipline)

A renderer declares `requires(params)` → a list of **needs**. A need means exactly
one thing: **"which expensive pipeline stage must run."** Nothing else. The
vocabulary is small, finite, and vendor-neutral, because each member maps to a real
cost boundary that already exists in the codebase:

| Need | Stage it runs | Existing seam |
| --- | --- | --- |
| `:header` | lazy open; read any header field (dims, orientation, EXIF/IPTC/XMP, ICC, interpretation) | `request/processor.ex:60-91` |
| `:pixels` | materialize the post-pipeline image | `Processor.materialize_for_delivery` |
| `{:detector, classes}` | run the object/face detector | `Transform.detector_*` (already gated + cache-folded) |
| `:source_bytes` | buffer the full raw source stream | the stream drain in `processor.ex` |

EXIF/IPTC/XMP are **not** a separate need: once the header is open, reading metadata
blocks is just more header field reads — they fold into `:header`.

**What is _not_ in `requires`** (and must never be): vendor semantics, field names,
and *all pure computation*. The renderer derives everything else itself over the
context it requested. The crop case is the proof the vocabulary does not fragment:
imgproxy info `crop:w:h:gravity` does **not** introduce a `:geometry` need. It
requires `:header` (dims) for center gravity, or `:header` + `:detector` for object
gravity, and then the renderer computes the crop rectangle itself by calling a
shared pure resolver over those inputs. Hashing is pure computation over
`:source_bytes`; palette/blurhash are pure computation over `:pixels`. The dividing
line:

- **In `requires` (neutral):** which expensive stages to run.
- **In the dialect renderer (vendor):** the field→need mapping, the wire key names,
  and every derivation (crop rectangles, fraction conversion, hash digests, palette
  quantization, EXIF tag naming).

Vendor-neutrality means the *shared* layer (need vocabulary + the satisfier that
runs stages + the `RenderContext` it fills) knows nothing about any dialect. The
imgproxy renderer's `requires/1` is vendor code returning neutral needs — that is
correct, not a leak. IIIF maps `width`/`height` → `[:header]`; imgproxy maps
`detect_objects` → `[:header, {:detector, "all"}]`. Different mappings, one neutral
vocabulary and one satisfier.

### The one honest wrinkle: `size`

`size` is **not** purely param-determined. It is cheap from HTTP `Content-Length` /
`File.stat`, but escalates to `:source_bytes` when the source carries no length. The
deliberate handling: the satisfier provides source length cheaply when available; if
a request demands `size` on a length-less source, the field either escalates to
`:source_bytes` or is omitted — a documented, deliberate degradation, not a clean
`requires` entry. This is the single place the model has a seam, and it is called
out rather than hidden.

### Flow

```
parse (dialect recognizes /info, emits render spec)
  → validate plan (empty pipeline allowed iff requires has no :pixels)
  → resolve source (unchanged safety boundary)
  → HTTPCache.prepare + conditional-GET (unchanged; 304-before-fetch preserved)
  → producer:
       requires = renderer.requires(params)
       satisfy(requires) → RenderContext            # Phase 1: only :header
       renderer.render(context, params) → {content_type, body}
       deliver body as a single-chunk response       # reuses Sender
```

`RenderContext` carries only what the declared needs populated:

```elixir
%RenderContext{
  info: %ImagePipe.Plan.SourceInfo{...},  # always (from :header)
  image: nil,        # populated by :pixels
  detections: nil,   # populated by {:detector, _}
  source_bytes: nil  # populated by :source_bytes
}
```

## Component decisions

### `ImagePipe.Plan.SourceInfo` (new, under `Plan.*`)

A product-neutral header-facts struct. It lives under `Plan.*` (**not** `Transform`/
`Request`) so renderers — which live under `Output.*` — can format over it without
forcing an `output → transform` boundary dependency.

```elixir
%ImagePipe.Plan.SourceInfo{
  format: :jpeg,            # SourceFormat.from_image/1 (vips-loader)
  mime_type: "image/jpeg",
  width: 1200, height: 800, # STORED (pre-orientation) dims; renderers swap as needed
  orientation: 1,           # "orientation" header, default 1
  byte_size: 123_456 | nil  # best-effort (Content-Length / File.stat), else nil
}
```

`width`/`height` are the **stored** (pre-rotation) dimensions plus the orientation
integer. Each renderer decides display semantics: imgproxy reports
orientation-adjusted dims for EXIF 5–8 (swap), IIIF reports final display dims. The
struct carries raw dims + orientation so both can derive correctly. Colorspace/
bands/sample_format/alpha/pages are **not** in the Phase-1 struct (see scope).

### `Plan.render` selector (minimal, not polymorphic `plan.output`)

`Plan` gains one optional field `render`, defaulting to `:image_encode`:

```elixir
render: :image_encode | %ImagePipe.Plan.Render{dialect: :imgproxy_info, params: %{...}}
```

- Default `:image_encode` → existing behavior, untouched; every current
  `plan.output` consumer is unaffected.
- A render spec carries a **neutral dialect tag + params**. The parser emits only
  the tag + params (preserving `parser → plan`). The Output layer maps the tag → a
  renderer module.
- `plan.output` (image-encode params: quality/format/color/hdr) stays **orthogonal**
  and is ignored for non-image renders. We do **not** make `plan.output` polymorphic
  — that would force every `Output`/cache-key/negotiation consumer to handle a
  variant it does not care about.

### `ImagePipe.Output.Render` behaviour (new, under `Output.*`)

```elixir
@callback requires(params) :: [need]
#   need :: :header | :pixels | {:detector, classes} | :source_bytes
@callback render(RenderContext.t(), params, keyword()) ::
            {:ok, {content_type :: String.t(), body :: iodata()}} | {:error, term()}
```

Renderers are **pure formatters** over the `RenderContext`. The existing image
encoder is reframed as the default renderer (it is conceptually `requires: [:pixels]`
+ image-bytes output; Phase 1 leaves the image path mechanically as-is and only adds
the non-image branch — see scope).

### imgproxy info renderer (`ImagePipe.Output.Render.ImgproxyInfo`)

Maps `SourceInfo` → imgproxy's JSON keys. Field-name renames happen here (the struct
field names are not the wire names): `byte_size` → `size`, orientation-adjusted
`width`/`height`, `mime_type` stays. The dialect-specific JSON shape lives here,
satisfying "dialect owns its schema" while keeping rendering mechanism under
`Output.*`.

### Non-image delivery

The delivery spine currently welds `Output.Resolved` into `PreparedStream` /
`SourceSession.Prepared` via `@enforce_keys`, and `Sender` reads `resolved_output`
for `[:deliver]` telemetry. A non-image body has no negotiated image format.
**Neutralize this:** the delivery carries a representation descriptor of which
`Output.Resolved` is one variant, so a JSON body does not need a sentinel
`Resolved`. (This work is needed for the future blurhash renderer regardless, so it
is not info-specific waste.) Add a thin `Response.*` helper to send a complete
non-image body (`content_type` + bytes), reused by info now and blurhash later.

### Telemetry

Rename the terminal span `[:encode]` → `[:render]` (encode is one renderer); carry a
`representation` metadata key (`:image` | `:json` | …). Update
`ImagePipe.Telemetry.Logger` subscription + rendering and `docs/telemetry.md` in the
same change (telemetry guidelines).

### Detector gate + cache identity read `requires`

The plug's `validate_detector_capability` and the cache-key detector-identity fold
(`runner.ex:238`) currently key off `Plan.detect_classes` (operation guides only). A
renderer can need the detector with **no operation guide** (e.g. info
`detect_objects`). Route the "detector needed?" decision through a single helper that
reads `Plan.detect_classes(plan)` **or** the render spec's `requires`. Phase 1's
renderer returns no detector need, so behavior is unchanged — but the seam is in
place so the future field is additive. The render selector (dialect tag + params)
must be part of the canonical cache key and the ETag inputs so `/info` and the image
render of the same source do not collide.

### Plan validation / empty pipeline

imgproxy `/info` ignores processing options, so the info plan has `pipelines: []`.
`Plan.validated_pipelines` rejects an empty pipeline with `:empty_pipeline_plan`.
Branch validation so an empty pipeline is allowed **iff** the render's `requires`
does **not** include `:pixels`. Gating on `requires` (not on "has a render
selector") prevents a future pixel-depth renderer from silently running on an
unprocessed image. All upstream safety (source resolution, bounded fetch,
`max_input_pixels`) is unaffected by an empty pipeline.

## Phase-1 scope

**Build:**

- `Plan.SourceInfo` (header facts: `format`, `mime_type`, `width`, `height`,
  `orientation`, `byte_size`).
- `Plan.render` field + `Plan.Render` spec + validation branch (empty pipeline iff
  no `:pixels`).
- `Output.Render` behaviour with `requires/1` returning an **open list**; Phase 1
  the imgproxy renderer returns `[:header]` only.
- The producer terminal fork: when `plan.render` is a spec, compute `requires`,
  satisfy (Phase 1: only the `:header` branch — `fetch_decode` already does this),
  build `RenderContext`, call the renderer, deliver the single-chunk body.
- `Output.Render.ImgproxyInfo` (header fields → imgproxy JSON).
- imgproxy `/info` dispatch in the parser: peel `/info`, verify signature, parse +
  ignore info-options, parse source (no extension split), emit the render spec.
- `Resolved`-neutralized delivery + `Response.*` non-image send helper.
- `[:render]` span rename + Logger + `docs/telemetry.md`.
- Wire-level Plug tests; `docs/imgproxy_support_matrix.md` rows (surface + stage/
  order axes), recording the deferred fields as a documented divergence.

**Implemented imgproxy info field set:** `format`, `mime_type`, `width`, `height`,
`orientation`, and `size` (best-effort `Content-Length` / `File.stat`).

**Do _not_ build (additive later, each a field + need + satisfier branch):**

- `exif` / `iptc` / `xmp` — header-cheap but need real metadata extraction; deferred
  as a **documented divergence** (the default imgproxy `/info` includes them).
- `colorspace` / `bands` / `sample_format` / `alpha` / `pages_number` — imgproxy
  marks these *slow* and **default-OFF**; including them would emit keys imgproxy
  omits by default (a parity break). They are **not** in the Phase-1 fixed set.
- All `:pixels` / `{:detector, _}` / `:source_bytes` satisfier branches and the
  fields that need them (`detect_objects`, `classify`, `crop`, `palette`, `average`,
  `dominant_colors`, `blurhash`, `thumb/perceptual_hash`, `hashsums`).
- The imgproxy info-option **grammar** (per-field toggles). Phase 1 returns the fixed
  set; the options segment is parsed-and-ignored so signatures verify.
- Caching of info responses MAY ride the existing machinery for free; if any part is
  deferred, note it explicitly and open a follow-up (issue permits this).

**Out of scope (separate issues):** IIIF parser + `info.json` (Phase 2); the
TwicPics-style `output=blurhash`/`lqip` producer-terminal renderer (roadmap; it is
an `:image`-depth representation that will reuse this protocol and the
`Resolved`-neutralized delivery).

## Forward-compatibility notes (not built now)

These are recorded so the Phase-1 shapes stay additive; none add Phase-1 code:

- **blurhash / lqip via `output=`** is an `:image`-depth representation selected on
  the *normal* processing plan (non-empty pipeline). It plugs into the same producer
  terminal renderer with `requires: [:pixels]`. It is the case that most justifies
  the renderer protocol, and it will also be where imgproxy info's slow pixel fields
  and TwicPics `meta` later converge.
- **IIIF `info.json`** is header-depth and rides the same pre-`:pixels` path, but
  `SourceInfo` serves only its `width`/`height`; the rest is static constants + the
  **service base URI** + server capability config (formats/sizes/tiles/profile). The
  info handler must keep `conn` + `opts` (mount config) reachable so IIIF can derive
  those — it already does, since the producer/request layer holds both. No new
  abstraction needed in Phase 1, but "additive for IIIF" depends on this.
- **info crop / detect** reuse `:header` + `{:detector, _}` and compute geometry via
  a shared pure crop-region resolver — not a `:geometry` need.

## Boundaries

- `parser → plan` only: the imgproxy parser emits a neutral `Plan.Render` tag +
  params; it never names a renderer module.
- `Plan.SourceInfo` and the render spec live under `Plan.*`.
- The `Output.Render` behaviour + renderers live under `Output.*` (rendering is
  output negotiation/encoding). They depend only on `Plan.*` (for `SourceInfo` /
  `RenderContext` neutral types) — **not** on `Transform.*`.
- The **request layer** (which already deps on `Transform`/`Source`/detector)
  assembles the `RenderContext` by running stages; renderers stay pure formatters, so
  no `output → transform` edge is created.
- Update `Boundary` declarations for the new `Plan` exports (`SourceInfo`, `Render`)
  and the new `Output.Render` surface.

## Testing

- Wire-level `ImagePipe.call/2` tests for a signed `/info` URL: 200 + `application/
  json` + decoded JSON field set; orientation-adjusted dims for an EXIF 5–8 source.
- Source-safety: an `/info` request that fails validation (bad signature, bad
  source) returns **before** any source fetch.
- Empty-pipeline render plan validates; a (synthetic) `:pixels`-requiring render plan
  with an empty pipeline is **rejected** (guards the future seam).
- `size` degradation: a length-less source omits/escalates rather than materializing
  the stream just for `size`.
- Telemetry: `[:render]` span emitted with the `representation` metadata; Logger
  renders it.

## Open questions resolved

- **Plan model:** minimal `Plan.render` selector, not polymorphic `plan.output`.
- **`byte_size`/`size`:** best-effort `Content-Length` / `File.stat`; documented
  degradation when absent.
- **Field set:** `format`, `mime_type`, `width`, `height`, `orientation`, `size`;
  `exif`/`iptc`/`xmp` deferred as a documented divergence; colorspace group excluded.
- **info-option grammar:** parse-and-ignore; fixed field set for Phase 1.
