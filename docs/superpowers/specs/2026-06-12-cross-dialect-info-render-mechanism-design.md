# Design: cross-dialect non-image render mechanism + imgproxy info API (Phase 1)

Issue: [#252](https://github.com/hlindset/image_plug/issues/252) — IIIF Image API support, Phase 1.
Type: `type:design`. Target: imgproxy compatibility (first consumer); IIIF `info.json` is Phase 2.

## Problem

`ImagePipe.Parser.parse/2` only yields an `ImagePipe.Plan`, and the response path
only emits encoded image bytes. There is no way to return a non-image (JSON/text)
response.

Three near-term consumers want one:

1. **imgproxy's info API** (`/info`) — facts about the source image (this Phase).
2. **imgproxy `format:blurhash` / `format:lqip`** on the *normal processing* path —
   a non-standard post-process representation of the **processed** image (roadmap,
   soon).
3. **IIIF `info.json`** — a service-capability advertisement (Phase 2).

These differ in purpose and in how deep into the image they reach, so the shared
layer must stay thin: it owns the **pipeline**, each dialect owns its **schema**.

## Upstream ground truth (imgproxy)

**The `/info` endpoint is a Pro-only feature and is _not_ implemented in the OSS
imgproxy source** (no `/info` route in `imgproxy.go`; the docs mark it `((pro))`).
The only ground truth is the documentation
(`/Users/hlindset/src/imgproxy-docs/docs/usage/getting_info.mdx`) and the URL/
signature docs (`signing_url.mdx`). We match the **documented** contract.

### `/info` is mixed-depth within one response

A single `/info` response can combine fields of very different cost. Grouped by what
they actually require:

| Cost tier | imgproxy info fields |
| --- | --- |
| header scalars (lazy open, no pixels) | `format`, `mime_type`, `width`, `height`, `orientation`, `colorspace`, `bands`, `sample_format`, `alpha`, `pages_number` |
| header metadata blocks (extraction) | `exif`, `iptc`, `xmp` |
| full pixel decode (+ detector/inference) | `detect_objects`, `classify`, `crop` (object gravity), `palette`, `average`, `dominant_colors`, `blurhash`, `thumb_hash`, `perceptual_hash` |
| entire raw byte stream | `size` (when no `Content-Length`), `hashsums` |

A request like `format:1/dimensions:1/detect_objects:1/hashsums:sha256` needs all
four tiers merged into one JSON document. **Depth is the union of the enabled
fields' needs** — see *the fold satisfier*.

The default-enabled fields are `size`, `format`, `dimensions`, `orientation`,
`exif`, `iptc`, `xmp`. Every pixel/stream-tier field is opt-in and default-OFF.

### URL grammar / signature (must-match)

```
/info/%signature/%info_options/plain/%source_url
/info/%signature/%info_options/%encoded_source_url
/info/%signature/%info_options/enc/%encrypted_source_url
```

- **`/info` is an UNSIGNED path prefix.** The HMAC covers
  `salt + "/" + info_options + "/" + source` — the leading `/info` is *not* in the
  signed payload. The dispatcher must **peel `/info` first, then run the existing
  signature extract/verify on the remainder.** (`Path.extract` treats segment 1 as
  the signature; an unpeeled `/info/...` URL mis-verifies.)
- **Info URLs carry no output extension.** The reused source parser must not run the
  `.`-split output-extension logic (`path.ex` `parse_plain_source` /
  `parse_encoded_source_value`), or `plain/http://x/a.jpg` mis-parses.
- **Info-options live _inside_ the signed path.** The options segment must be
  *parsed* (so the signed string is reconstructed byte-identically), even though
  Phase 1 ignores the *display* options' effect. **`expires` and `cachebuster` must
  be parsed _and honored_** (not ignored): `expires` → 404 when expired is a
  security/policy option that already flows through the planner.

Source decoding (encoded / `plain` / `enc`) is otherwise identical to the
processing endpoint and is reused.

## Design principle

The shared layer owns the **pipeline**, not the **schema**. We do **not** model a
unified info document: imgproxy info reports facts about an image; IIIF `info.json`
is a service-capability advertisement; blurhash/lqip are representations of the
processed image. Each dialect/representation owns its serializer; the core knows
only "a non-image terminal renderer produces a complete body."

## Architecture: the terminal stage becomes a Renderer

The producer (`lib/image_pipe/request/source_session/producer.ex`
`prepare_first_chunk/1`, ~114–166) has two distinct spines, reused very differently:

- **Compute spine** — `fetch → decode → (transform → materialize) → terminal`. Every
  response uses this, stopping at the depth it needs.
- **Streaming-delivery spine** — the `PreparedStream` chunked/cancellable machinery,
  with `Output.Resolved` welded into `PreparedStream` / `SourceSession.Prepared` via
  `@enforce_keys`. **Only image-encode uses this** (large, chunked output).

**Key observation: rendered representations are never streams — they are small,
fully-known complete bodies** (a JSON doc, a blurhash string, an lqip data-URI). So
renders run on the *compute* spine but bypass the *streaming-delivery* spine
entirely, returning a complete body. This is what keeps `PreparedStream`/`Resolved`
image-encode-only — there is **no `Resolved`-neutralization to do.**

The producer terminal forks on render kind:

```
... → materialize → TERMINAL:
   default image-encode renderer  → encode_first_chunk → PreparedStream (streaming; unchanged)
   non-image renderer             → render(context) → {:rendered, content_type, iodata} (complete body)
```

`depth` (from `requires`, below) controls how far the compute spine runs before the
terminal: `:header` stops after decode; `:pixels` runs transform + materialize. The
streaming spine and its `Resolved` welding are untouched.

### The `requires` contract (the load-bearing discipline)

A renderer declares `requires(params)` → a list of **needs**. A need means exactly
one thing: **"which expensive pipeline stage must run."** Not vendor semantics, not
computations. The vocabulary is small, finite, vendor-neutral — each member is a
real cost boundary that already exists:

| Need | Stage it runs | Existing seam |
| --- | --- | --- |
| `:header` | lazy open; read header scalars (dims, format, orientation, interpretation) | `request/processor.ex:60-91` (`header_image`) |
| `:pixels` | materialize the post-pipeline image | `Processor.materialize_for_delivery` |
| `{:detector, classes}` | run the object/face detector | `Transform.detector_*` (gated + cache-folded) |
| `:source_bytes` | buffer the full raw source stream | the stream drain in `processor.ex` |

`requires/1` returns an **open list**; Phase 1's imgproxy-info renderer returns
`[:header]`. We do **not** enumerate the other members as dead arms — they appear
with the field/renderer that first needs them.

**What is _not_ in `requires`** (and must never be): vendor field semantics, wire
key names, and *all pure computation*. The renderer derives everything else over the
context it requested. The crop case proves the vocabulary does not fragment:
imgproxy info `crop:w:h:gravity` introduces **no `:geometry` need** — it requires
`:header` (dims) for center gravity, or `:header` + `{:detector,_}` for object
gravity, and computes the crop rectangle *itself* by calling a shared pure resolver
over those inputs. Hashing is pure over `:source_bytes`; palette/blurhash are pure
over `:pixels`.

- **In `requires` (neutral):** which expensive stages to run.
- **In the dialect renderer (vendor):** the field→need mapping, the wire key names,
  and every derivation (crop rectangles, fraction conversion, hash digests, palette
  quantization, EXIF tag naming).

`requires/1` is vendor code returning *neutral* needs — that is correct, not a leak.
IIIF maps `width`/`height` → `[:header]`; imgproxy maps `detect_objects` →
`[:header, {:detector, "all"}]`. Different mappings, one neutral vocabulary and one
satisfier.

`:pixels` means **the materialized result of _this plan's_ pipeline** — empty
pipeline → the decoded source (imgproxy info's own `palette`/`blurhash`); full
pipeline → the processed image (TwicPics/imgproxy `format:blurhash`). The
source-vs-processed distinction is handled by "this plan's pipeline," not by a
separate need. (Phase 1 builds no `:pixels` handler; this definition is the contract
the first `:pixels` renderer implements.)

### The fold satisfier and mixed bags

The satisfier is a **fold over the needs set**, not a depth branch:

```
satisfy(requires):
  context = %RenderContext{}
  for each need in normalize(requires):     # run every declared stage, in dep order
    run the stage, populate its context slot
  → one context (info / image / detections / source_bytes populated as needed)
renderer.render(context, params) → one merged document
```

A **mixed bag** (headers + pixels + detector + raw bytes in one response) is the
*designed-for* case, not an edge case — it is why `requires` is a set and the
context has multiple slots. A union just runs more stages and fills more slots, then
the renderer merges. **No split-and-merge**: one compute pass, one context, one
renderer, one document.

Two mechanical concerns, both handled:

1. **Implication + ordering.** `normalize/1` expands implied needs
   (`{:detector,_}` ⟹ `:pixels` ⟹ decode ⟹ `:header`), then stages run in a fixed
   dependency order: `fetch → (buffer raw if :source_bytes) → decode (:header) →
   transform+materialize (:pixels) → detect (:detector) → render`. `:header` is free
   in any mixed bag once anything decodes.
2. **One fetch, shared.** `:source_bytes` (hash the original file) and `:pixels`
   (decode the image) both consume the fetched source, which is fetched **once**: the
   existing path drains to a buffer and decodes *from* it, so "hash the buffer" +
   "decode the buffer" compose on a single read.

**Deferred policy (not decided now):** when a *required* stage in a mixed bag cannot
run (detector unavailable, image exceeds `max_input_pixels` for `:pixels`), does the
render fail the whole request or omit that field and return a partial document?
imgproxy tends to fail; partial/omit is a per-field policy settled when those fields
exist. Phase 1 (header-only) never hits this.

### The `size` wrinkle

`size` is **not** purely param-determined. It is cheap from HTTP `Content-Length` /
`File.stat`. **Phase 1: present when cheaply available, else omit.** imgproxy
*downloads* the source to compute size when no `Content-Length` is present — that
fallback is a documented divergence (the escalation to `:source_bytes` is a
forward-note, not built now, since `:source_bytes` is deferred).

### RenderContext

Assembled by the request layer; renderers are pure formatters over it.

```elixir
%RenderContext{
  info: %ImagePipe.Plan.SourceInfo{...}   # always (from :header)
  # image / detections / source_bytes fields are ADDED with their stage handlers,
  # not declared now (they would be permanently nil in Phase 1).
}
```

**Boundary discipline for the future `image` field:** when the first `:pixels`
renderer lands, `RenderContext.image` is typed `Vix.Vips.Image.t()` — a plain Vix
image (external library), the **same** type `Output.Encoder.stream_output/3` already
receives. It must **not** carry a `Transform.State` or a detector-internal struct.
So renderers under `Output.*` format over external Vix + neutral `Plan.*` types only
— no `Output → Transform` edge is created.

## Component decisions

### `ImagePipe.Plan.SourceInfo` (new, under `Plan.*`)

Product-neutral header facts. Lives under `Plan.*` (not `Transform`/`Request`) so
renderers (under `Output.*`) can format over it without an `output → transform`
edge.

```elixir
%ImagePipe.Plan.SourceInfo{
  format: :jpeg,            # plain atom
  mime_type: "image/jpeg",
  width: 1200, height: 800, # STORED (pre-orientation) dims
  orientation: 1,           # "orientation" header, default 1
  byte_size: 123_456 | nil  # best-effort (Content-Length / File.stat), else nil
}
```

- Sourced from the **`header_image`** (`processor.ex:64-68`), which already exposes
  format, dims, and the EXIF orientation header — not the shrink-on-load decode
  image.
- The **request layer** calls `Request.SourceFormat.from_image/1` and stores a plain
  atom; `Plan.*` must **not** alias `Request.SourceFormat` (would create a
  `plan → request` edge).
- `width`/`height` are **stored** (pre-rotation) dims + the orientation integer.
  Each renderer decides display semantics (imgproxy reports orientation-adjusted
  dims, swapping for EXIF 5–8; IIIF reports final display dims).
- Colorspace/bands/sample_format/alpha/pages are **not** in the Phase-1 struct (see
  scope).

### `Plan.render` selector (minimal; not polymorphic `plan.output`)

`Plan` gains one optional field `render`, default `:image_encode`:

```elixir
render: :image_encode | %ImagePipe.Plan.Render{renderer: tag, params: map}
```

- Default `:image_encode` → existing behavior, untouched.
- A render spec carries a **neutral renderer tag + params**. The parser emits only
  the tag + params (preserving `parser → plan`); the Output layer maps the tag → a
  renderer module.
- `plan.output` (image-encode params) stays **orthogonal** and is ignored for
  non-image renders. We do **not** make `plan.output` polymorphic.

**Two selection paths (both set `plan.render`, agnostic to which):**

1. **Endpoint** — the imgproxy parser recognizes `/info` and emits an
   `:imgproxy_info` render spec (header-depth, empty pipeline).
2. **Output-format option** — the imgproxy `format`/`f` handler forks: image formats
   (`avif`/`webp`/`jpeg`/`png`) → `plan.output.mode`; render kinds
   (`blurhash`/`lqip`) → `plan.render` (full pipeline preserved, output params
   ignored). This non-standard `format` extension is isolated in the imgproxy
   parser/option-grammar (dialect-quirk rule). *(Roadmap, not Phase 1.)*

**Render-tag namespace splits into neutral and dialect-specific.** `:blurhash` /
`:lqip` are *product-neutral* representations — one renderer under `Output.*`, shared
by imgproxy `format:blurhash` and TwicPics `output=blurhash`; only the *selection
syntax* differs per parser. `:imgproxy_info` (and later `:iiif_info`) are
*dialect-specific* schemas. The parser maps its syntax to the right tag; the renderer
owns the representation.

### `ImagePipe.Output.Render` behaviour (new, under `Output.*`)

```elixir
@callback requires(params) :: [need]              # open list; Phase 1: [:header]
#   need :: :header | :pixels | {:detector, classes} | :source_bytes
@callback render(RenderContext.t(), params, keyword()) ::
            {:ok, {content_type :: String.t(), body :: iodata()}} | {:error, term()}
```

Renderers are pure formatters over `RenderContext`. The existing image encoder is the
conceptual default renderer; Phase 1 leaves the image-encode path mechanically as-is
and only adds the non-image terminal branch.

### `ImagePipe.Output.Render.ImgproxyInfo` (new, dialect-specific)

Maps `SourceInfo` → imgproxy JSON keys. Field renames happen here (struct field names
are not wire names): `byte_size` → `size`, orientation-adjusted `width`/`height`,
`mime_type` stays. `requires/1` → `[:header]`.

**`mime_type` must cover source-only formats.** imgproxy `/info` reports the
*source* MIME, routinely a source-only format (TIFF/HEIC). `ImagePipe.Format` today
maps MIME only for the four *output* formats; **extend the source-format → MIME
mapping** (`heif`/`tiff`/`jpeg2000`/`jpeg_xl`) so `mime_type` is correct for those
inputs. (Without this, TIFF/HEIC sources produce a wrong/`:error` `mime_type` — a
latent bug inside the declared field set.)

### Non-image delivery (complete body)

Renders bypass `PreparedStream` and `Resolved` entirely:

- `Runner` returns `{:rendered, content_type, iodata(), CacheHeaders.t()}`.
- A new `Sender.send_result/3` clause sends it with `send_resp/3`; a thin
  `Response.*` helper owns content-type + body. Reused by info now and
  blurhash/lqip later.
- `Sender`'s render error path needs a tag + clause (the image-centric
  `@plan_validation_error_tags` / `handle_processing_error` don't cover
  `{:error, _}` from `render/3`).
- **Caching:** a rendered body is a complete body, which maps cleanly onto the
  existing complete-body `Cache.Entry` path. Phase 1 MAY cache rendered responses
  via that path; if deferred, the render selector still folds into the cache key so
  it is additive (open a follow-up). The streaming cache-sink
  (`source_session.ex:259`) is *not* involved, since renders don't stream.

### Telemetry

Rename the terminal span `[:encode]` → `[:render]` (encode is one renderer); carry a
`representation` metadata key (`:image` | `:json` | …). Update
`ImagePipe.Telemetry.Logger` (subscription + a `message/3` clause that still surfaces
the outcome) and `docs/telemetry.md` in the same change.

### Plan validation

- `Plan.validate_shape` learns the new `render` field (a `validate_render` clause +
  a `shape_error` member); default `:image_encode` passes trivially.
- **Empty-pipeline gate.** imgproxy `/info` has `pipelines: []`, which
  `Plan.validated_pipelines` rejects (`:empty_pipeline_plan`). Allow an empty
  pipeline for a **header-depth** render plan (a render spec whose `requires` lacks
  `:pixels`). This must hold at the pre-fetch gate `validate_prefetch_safe_plan`
  (`plug.ex:133`, called before source resolution), not only in the deeper
  `validated_pipelines`. **No synthetic-`:pixels`-rejection test in Phase 1** — that
  test arrives with the first real `:pixels` renderer (fabricating a `:pixels` render
  plan now would be an impossible-internal-misuse test, which the repo forbids).

### Cache key / ETag

Fold the render selector into the **existing** `representation:` slot of
`Cache.Key.plan_material/2` (`key.ex:62-75`), which flows into both the cache key and
the input-derived ETag (`http_cache.ex`). This separates `/info` from the image
render of the same source and preserves the 304-before-fetch fast path (the ETag
stays input-derived, never a body hash). The info plan's `Output` mode must **not**
be `:automatic`, so no spurious `Vary: Accept` is emitted on a non-negotiated JSON
response (an explicit render bypasses `Accept` negotiation, like `format:avif`).

### imgproxy `/info` dispatch

In the imgproxy parser: peel `/info`, verify the signature on the remainder, parse
source (no output-extension split), parse-and-honor `expires`/`cachebuster`,
parse-and-ignore the display info-options, and emit
`%Plan.Render{renderer: :imgproxy_info, params: %{}}` with `pipelines: []`.

## Phase-1 scope

**Build:**

- `Plan.SourceInfo` (`format`, `mime_type`, `width`, `height`, `orientation`,
  `byte_size`), sourced from `header_image`.
- `Plan.render` field + `Plan.Render` spec + `validate_shape`/empty-pipeline branch.
- `Output.Render` behaviour (`requires/1` open list, `render/3`) + `RenderContext`
  with the `info:` field only.
- The producer terminal fork + a **fold satisfier** that implements only the
  `:header` stage (decode already does it), builds the context, calls the renderer,
  returns `{:rendered, …}`.
- `Output.Render.ImgproxyInfo` (header fields → imgproxy JSON; source-format MIME).
- imgproxy `/info` dispatch (peel/verify/no-extension/honor-expires/ignore-display).
- `{:rendered}` delivery: `Runner` result, `Sender.send_result/3` clause + render
  error tag, `Response.*` complete-body helper.
- `[:render]` span rename + Logger + `docs/telemetry.md`.
- Source-format MIME mapping extension in `ImagePipe.Format`.
- Wire-level Plug tests; `docs/imgproxy_support_matrix.md` (surface + stage/order +
  **behavioral** axes; stale-line cleanup).

**Implemented imgproxy info field set:** `format`, `mime_type`, `width`, `height`,
`orientation`, `size` (best-effort).

**Do _not_ build** (additive later, each a field + need + satisfier-fold branch):

- `exif` / `iptc` / `xmp` — they ride `:header` (no extra stage) but need real
  metadata-block extraction + imgproxy naming; deferred as a **documented divergence**
  (the default imgproxy `/info` includes them — see below).
- `colorspace` / `bands` / `sample_format` / `alpha` / `pages_number` — imgproxy
  marks these *slow* and **default-OFF**; emitting them would add keys imgproxy omits
  by default. **Excluded** from the fixed set.
- All `:pixels` / `{:detector, _}` / `:source_bytes` fold branches and the fields
  needing them (`detect_objects`, `classify`, `crop`, `palette`, `average`,
  `dominant_colors`, `blurhash`, `thumb/perceptual_hash`, `hashsums`).
- The imgproxy info-option **grammar** (per-field toggles). Phase 1 returns the fixed
  set; the options segment is parsed (for signature reconstruction) but its display
  toggles are ignored. `expires`/`cachebuster` are still honored.
- The `format:blurhash`/`format:lqip` output-format render path (roadmap).
- The detector-gate / cache-identity `or requires` plumbing (no Phase-1 caller).

**Out of scope (separate issues):** IIIF parser + `info.json` (Phase 2); the
blurhash/lqip `:pixels` renderers and the producer `:pixels` fold branch.

## Compatibility divergences (record in `docs/imgproxy_support_matrix.md`)

The matrix update must cover **surface**, **stage/order**, *and* **behavioral**
axes, and must remove the now-stale "no info endpoint" statements and revisit the
`IMGPROXY_INFO_PRESETS*` rows. Explicit divergences:

1. **Default response is a strict subset.** A bare `/info/SIG/plain/url` (no options)
   in imgproxy returns `size`, `format`/`mime_type`, `width`/`height`/`orientation`,
   **and** the default-ON `exif`/`iptc`/`xmp` blocks. ImagePipe Phase 1 returns the
   first groups and **omits exif/iptc/xmp** — the *default, most-common* response
   diverges, not just an opt-in field. State this plainly.
2. **`size` omit-vs-download.** ImagePipe omits `size` on a length-less source;
   imgproxy downloads to compute it.
3. **Excluded slow fields.** colorspace/bands/sample_format/alpha/pages_number are
   not emitted (matches imgproxy defaults; recorded so it's intentional).

## Forward-compatibility notes (not built now)

- **`format:blurhash` / `format:lqip` on the normal path** select `plan.render` via
  the imgproxy `format` option, on a **full-pipeline** plan → `requires: [:pixels]`.
  The producer runs the same transform+materialize an image request runs, then forks
  the terminal to the renderer. `:blurhash`/`:lqip` are **neutral** renderers shared
  with TwicPics `output=`. **lqip may encode internally** (downscale → encode a tiny
  image → base64 → data-URI) — a render can call `Output.Encoder` as a sub-step; it
  still returns a complete `{:rendered}` body. These are additive: a depth value, a
  neutral renderer module, and a parser `format`-value mapping.
- **IIIF `info.json`** is header-depth but `SourceInfo` serves only its
  `width`/`height`; the rest is static constants + the **service base URI** + server
  capability config (formats/sizes/tiles/profile). The info handler must keep
  `conn` + `opts` reachable for the renderer to derive those (it does, since the
  request layer holds both) — but "additive for IIIF" depends on threading that
  request/mount context into the renderer's inputs; settle the carrier shape when
  Phase 2 starts rather than assuming `RenderContext` as drawn suffices.
- **Detector gate + cache identity** will read the render `requires` in addition to
  `Plan.detect_classes`/`face_assist?` when an info field first needs the detector;
  route that through a single helper then (preserving the `face_assist?` branch).
- **Mixed-bag partial-vs-fail** policy (above) is decided when the first
  pixel/detector/source_bytes field ships.

## Boundaries

- `parser → plan` only: the imgproxy parser emits a neutral `Plan.Render` tag +
  params; it never names a renderer module.
- `Plan.SourceInfo`, `Plan.Render` (and `RenderContext` if it lands here) live under
  `Plan.*`; add them to `Plan`'s `Boundary` exports.
- `Output.Render` behaviour + renderers live under `Output.*`; add to `Output`'s
  exports. They depend only on `Plan.*` (+ external Vix for the future `:pixels`
  image) — **not** on `Transform.*`.
- The **request layer** (already deps on `Transform`/`Source`/detector) runs the
  satisfier stages and fills `RenderContext`; renderers stay pure formatters, so no
  `output → transform` edge. The satisfier must reach the detector/materialize
  **through the `Transform` facade**, never a concrete op module (architecture test).

## Testing

- Wire-level `ImagePipe.call/2` for a signed `/info` URL: 200 + `application/json` +
  decoded JSON field set; orientation-adjusted dims for an EXIF 5–8 source; a
  source-only format (e.g. TIFF) returns the correct `mime_type`.
- Source-safety: an `/info` request that fails validation (bad signature, bad
  source) returns **before** any source fetch.
- `expires`: an expired `/info` URL returns 404.
- No `Vary: Accept` on the JSON response.
- Empty-pipeline header-depth render plan validates (no synthetic `:pixels` plan).
- `size` degradation: a length-less source omits `size` rather than downloading.
- Telemetry: `[:render]` span with `representation` metadata; Logger renders it.

## Open questions resolved

- **Delivery:** complete-body `{:rendered}` path; renders never touch
  `PreparedStream`/`Resolved` (no neutralization needed).
- **Invocation site:** the producer terminal (one site for header and future pixel
  renders; reuses fetch/decode), not a separate request-layer path.
- **Plan model:** minimal `Plan.render` selector; `plan.output` untouched.
- **`size`:** best-effort, omit when absent; download-fallback is a divergence.
- **Field set:** `format`/`mime_type`/`width`/`height`/`orientation`/`size`;
  exif/iptc/xmp deferred (documented divergence); colorspace group excluded.
- **info-option grammar:** parse for signature, ignore display toggles, honor
  `expires`/`cachebuster`; fixed field set.
- **`requires` mapping:** vendor-neutral (expensive-stage selection only); mixed bags
  via a fold over the union; `requires/1` is vendor code returning neutral needs.
