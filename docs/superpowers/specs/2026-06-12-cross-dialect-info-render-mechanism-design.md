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
fields' needs** — see *the satisfier* (forward generalization).

The default-enabled fields are `size`, `format`, `dimensions`, `orientation`,
`exif`, `iptc`, `xmp` (and `video_meta` for video, which ImagePipe does not handle).
Every pixel/stream-tier field is opt-in and default-OFF.

### URL grammar / signature (must-match)

```
/info/%signature/%info_options/plain/%source_url
/info/%signature/%info_options/%encoded_source_url
/info/%signature/%info_options/enc/%encrypted_source_url
```

- **`/info` is an UNSIGNED path prefix.** The HMAC covers
  `salt + "/" + info_options + "/" + source` — the leading `/info` is *not* in the
  signed payload (`signing_url.mdx`). The dispatch must **peel `/info` first, then
  run the existing signature extract/verify on the remainder.** `Path.extract`
  (`path.ex:7-20`) treats path segment 1 as the signature, so the fork lives in
  `parse_request/2` (imgproxy.ex): detect a leading `/info` segment and call a
  peeled variant before `extract`.
- **Info URLs carry no output extension.** The **encoded** source parser
  (`parse_encoded_source_value`, `path.ex:111`) splits on `.` to extract an output
  format; that split must be bypassed for info, or an encoded info source mis-parses
  its trailing `.segment`. (The `plain` parser splits on `@`, not `.`, so plain is
  unaffected — but the no-extension rule applies to both forms.)
- **Info-options live _inside_ the signed path.** The options segment must be
  *parsed* so the signed string is reconstructed byte-identically, even though Phase
  1 ignores the *display* options' effect. **`expires` and `cachebuster` must be
  parsed _and honored_** (not ignored): `expires` → 404 when expired is enforced in
  `plan_builder.ex` `reject_expired_request` during parsing, before any fetch — the
  `/info` dispatch must route through that same planner policy path.

Source decoding (encoded / `plain` / `enc`) is otherwise identical to the
processing endpoint and is reused.

## Design principle

The shared layer owns the **pipeline**, not the **schema**. We do **not** model a
unified info document: imgproxy info reports facts about an image; IIIF `info.json`
is a service-capability advertisement; blurhash/lqip are representations of the
processed image. Each dialect/representation owns its serializer; the core knows
only "a non-image terminal renderer produces a complete body."

## Architecture: a non-image render path in the request layer

The producer (`lib/image_pipe/request/source_session/producer.ex`) is the
**streaming-encode machine**: a spawned process with a `{:next}`/`{:halt}` demand
protocol whose `prepare_first_chunk/1` (~114–166) is one `with` chain hard-wired to
`resolve_output → clamp → materialize → encode_first_chunk`, every step consuming or
producing `%Output.Resolved{}`, and whose `SourceSession` reply path opens the cache
sink from that `Resolved` (`source_session.ex:259`). It exists to stream large,
chunked, cancellable **encoded image** bytes. It is **not** a generic compute engine
with a pluggable terminal — its compute and its streaming protocol are the same
chain in the same process.

**Rendered representations are small, fully-known complete bodies** (a JSON doc, a
blurhash string, an lqip data-URI) — never streams. So a render must **not** go
through the producer/`SourceSession`. Instead, a render runs in the **request layer**
(`Runner`), calling the already-public `Request.Processor` entry points to the depth
it needs, then formats and returns a complete body:

```
Runner, when plan.render is a render spec:
  decoded = Processor.fetch_decode_validate_source_with_source_format(plan, resolved_source, opts)   # :header depth
  # (future :pixels depth: Processor.process_source/3 — fetch+decode+transform+materialize)
  context = build_render_context(decoded, requires)        # Phase 1: %RenderContext{info: SourceInfo}
  {:ok, {content_type, body}} = renderer.render(context, params, opts)
  → {:rendered, content_type, body, prepared_http_cache}
```

This path **never starts `SourceSession`/`Producer`, never constructs `%Resolved{}`,
never opens the streaming cache sink.** `PreparedStream`/`Resolved` stay
image-encode-only and untouched — there is no neutralization to do. It still runs
after `parse → validate → resolve source → HTTPCache.prepare → conditional-GET` in
`plug.ex`, so source-safety and the 304-before-fetch path are reused.

> **Forward note (heavy `:pixels` renders):** a `:header` render is cheap and runs
> synchronously in the request process. A future `:pixels` render (blurhash/lqip)
> does real transform+materialize work via `Processor.process_source/3`; if
> disconnect-cancellation of that CPU work matters, wrap the render compute in a
> monitored `Task` then. Not a Phase-1 concern.

### The `requires` contract (the load-bearing discipline)

A renderer declares `requires(params)` → a list of **needs**. A need means exactly
one thing: **"which expensive pipeline stage must run."** Not vendor semantics, not
computations. The vocabulary is a small, finite, vendor-neutral set — each member a
real cost boundary that already exists. Phase 1 inhabits **only `:header`**, so the
Phase-1 typespec is `need :: :header`; the union widens at the first renderer that
returns another member (no dead arms written now):

| Need (eventual) | Stage it runs | Existing seam |
| --- | --- | --- |
| `:header` (Phase 1) | lazy open; read header scalars (dims, format, orientation, interpretation) | `request/processor.ex:60-91` (`header_image`) |
| `:pixels` (next) | materialize the post-pipeline image | `Processor.process_source/3` → `final_state.image` |
| `{:detector, classes}` | run the object/face detector | `Transform.detector_*` |
| `:source_bytes` | buffer the full raw source stream | the stream drain in `processor.ex` |

**What is _not_ in `requires`** (and must never be): vendor field semantics, wire
key names, and *all pure computation*. The renderer derives everything else over the
context. The crop case proves the vocabulary does not fragment: imgproxy info
`crop:w:h:gravity` introduces **no `:geometry` need** — it requires `:header` (dims)
for center gravity, or `:header` + `{:detector,_}` for object gravity, and computes
the crop rectangle *itself*. Hashing is pure over `:source_bytes`; palette/blurhash
are pure over `:pixels`.

- **In `requires` (neutral):** which expensive stages to run.
- **In the dialect renderer (vendor):** the field→need mapping, the wire key names,
  the wire format/mime spellings, and every derivation.

`requires/1` is vendor code returning *neutral* needs. IIIF maps `width`/`height` →
`[:header]`; imgproxy maps `detect_objects` → `[:header, {:detector, "all"}]`.

`:pixels` means **the materialized result of _this plan's_ pipeline** — empty
pipeline → the decoded source (imgproxy info's own `palette`/`blurhash`); full
pipeline → the processed image (TwicPics / imgproxy `format:blurhash`). The
source-vs-processed distinction is handled by "this plan's pipeline," not a separate
need.

### The satisfier (Phase 1 straight-line; fold is the forward generalization)

Phase 1 has one need, so the satisfier is straight-line:

```
build_render_context(decoded, [:header]) → %RenderContext{info: SourceInfo.from_decoded(decoded)}
```

**Forward generalization (not built now):** with ≥2 needs the satisfier becomes a
**fold over the union** — normalize the set (expand implications
`{:detector,_}` ⟹ `:pixels` ⟹ decode ⟹ `:header`), run stages in a fixed dependency
order (`fetch → buffer-raw → decode → transform+materialize → detect → render`),
populate one `RenderContext` with multiple slots, and let the renderer merge. A
**mixed bag** (header + pixels + detector + raw bytes in one response — imgproxy
`/info` at full surface) is then the natural case: a union runs more stages and fills
more slots; **no split-and-merge**. The source is fetched **once** (drained to a
buffer; `:source_bytes` hashes the buffer, `:pixels` decodes from it). Phase 1 ships
the one-element case directly and documents the fold as the generalization point —
building `normalize/1` and a fold over a one-element list now would be dead code.

> **Deferred policy:** in a mixed bag, if a required stage cannot run (detector
> unavailable, image exceeds `max_input_pixels` for `:pixels`), does the render fail
> the request or omit that field? imgproxy tends to fail; partial/omit is settled
> when those fields exist. Phase 1 (header-only) never hits this.

### The `size` wrinkle

`size` is cheap from HTTP `Content-Length` / `File.stat`. **Phase 1: present when
cheaply available, else omit.** imgproxy *downloads* to compute size when no
`Content-Length` is present — that fallback is a documented divergence (escalation to
`:source_bytes` is a forward-note, not built now). `size` is sourced by the request
layer from the `Source.Response`/`File.stat`, **not** from the decoded image (see
`SourceInfo.byte_size` below).

### `Plan.RenderContext` (hard placement: under `Plan.*`)

Assembled by the request layer; renderers are pure formatters over it. It **must**
live under `Plan.*` (not `Request.*`): `Output.Render.render/3` takes it as an
argument, so its owning boundary becomes a dep of `Output`, and `output → request` is
forbidden (`output → plan` already exists).

```elixir
%ImagePipe.Plan.RenderContext{
  info: %ImagePipe.Plan.SourceInfo{...}   # always (from :header)
  # image / detections / source_bytes fields are ADDED with their stage handlers,
  # not declared now (they would be permanently nil in Phase 1).
}
```

When the first `:pixels` renderer lands, `RenderContext.image` is typed
`Vix.Vips.Image.t()` — a plain Vix image (external library), the **same** type
`Output.Encoder.stream_output/3` already receives. It must **not** carry a
`Transform.State` or detector-internal struct, so `Output.*` renderers format over
external Vix + neutral `Plan.*` types only — no `output → transform` edge.

## Component decisions

### `ImagePipe.Plan.SourceInfo` (new, under `Plan.*`)

Product-neutral facts. Header scalars come from the `header_image`
(`processor.ex:64-68`); `byte_size` is the **one non-header field**, filled by the
request layer from `Source.Response`/`File.stat` (nil when neither is available).

```elixir
%ImagePipe.Plan.SourceInfo{
  format: :jpeg,            # neutral atom (from Request.SourceFormat.from_image/1)
  width: 1200, height: 800, # STORED (pre-orientation) dims
  orientation: 1,           # "orientation" header, default 1
  byte_size: 123_456 | nil  # request-layer: Content-Length / File.stat, else nil
}
```

- The **request layer** calls `Request.SourceFormat.from_image/1` and stores a plain
  atom; `Plan.*` must **not** alias `Request.SourceFormat` (would create a
  `plan → request` edge).
- `width`/`height` are **stored** (pre-rotation) dims + the orientation integer; each
  renderer decides display semantics (imgproxy swaps for EXIF 5–8; IIIF reports final
  display dims).
- No `mime_type` field: MIME is a wire spelling owned by each renderer (below).
  Colorspace/bands/sample_format/alpha/pages are **not** in the Phase-1 struct.

### `Plan.render` selector (minimal; not polymorphic `plan.output`)

`Plan` gains one optional field `render`, default `:image_encode`:

```elixir
render: :image_encode | %ImagePipe.Plan.Render{renderer: tag, params: map}
```

- Default `:image_encode` → existing behavior, untouched.
- A render spec carries a **neutral renderer tag + params**; the parser emits only
  the tag + params (preserving `parser → plan`); the Output layer maps tag → module.
- `plan.output` (image-encode params) stays **orthogonal** and is ignored for
  non-image renders. We do **not** make `plan.output` polymorphic.

**Two selection paths (both set `plan.render`):**

1. **Endpoint** — the imgproxy parser recognizes `/info` and emits an
   `:imgproxy_info` render spec (header-depth, empty pipeline).
2. **Output-format option** *(roadmap, not Phase 1)* — the imgproxy `format`/`f`
   handler forks: image formats → `plan.output.mode`; render kinds
   (`blurhash`/`lqip`) → `plan.render` (full pipeline preserved). This non-standard
   `format` extension is isolated in the imgproxy parser/option-grammar.

**Render-tag namespace splits neutral vs dialect-specific.** `:blurhash`/`:lqip` are
*product-neutral* representations — one renderer under `Output.*`, shared by imgproxy
`format:blurhash` and TwicPics `output=blurhash`; only selection syntax differs per
parser. `:imgproxy_info` (later `:iiif_info`) are *dialect-specific* schemas.

### `ImagePipe.Output.Render` behaviour (new, under `Output.*`)

```elixir
@callback requires(params) :: [need]              # Phase 1: need :: :header
@callback render(RenderContext.t(), params, keyword()) ::
            {:ok, {content_type :: String.t(), body :: iodata()}} | {:error, term()}
```

Renderers are pure formatters over `RenderContext`. The existing image encoder is the
conceptual default renderer; Phase 1 leaves the image-encode path mechanically as-is
and only adds the request-layer render branch.

### `ImagePipe.Output.Render.ImgproxyInfo` (new, dialect-specific)

Maps `SourceInfo` → imgproxy JSON. `requires/1` → `[:header]`. **Owns the imgproxy
wire spellings** (vendor naming, sourced from imgproxy `imagetype/defs.go`):

- `format` + `mime_type`: an atom → `{imgproxy_format_string, mime}` table.
  imgproxy spells HEIC `"heic"`/`image/heif`, JXL `"jxl"`/`image/jxl`, TIFF
  `"tiff"`/`image/tiff`, AVIF `"avif"`/`image/avif`, plus jpeg/png/webp/gif. It has
  **no `heif` or `jpeg2000` type** — do not invent them. This table lives in the
  renderer, **not** in `ImagePipe.Format` (those strings are imgproxy spellings, not
  neutral facts).
- `width`/`height`: orientation-adjusted (swap stored dims for EXIF 5–8).
- `size` from `byte_size`; `orientation` from `SourceInfo.orientation`.

**Detection divergence to record:** ImagePipe's `SourceFormat.from_image`
(`source_format.ex:39-43`) classifies HEIF via the libvips loader + `heif-compression`
(`av1` → `:avif`, else `:heif`/HEIC), whereas imgproxy detects HEIC vs AVIF from
magic bytes. The mappings agree for typical inputs but the detection path differs —
note it in the matrix.

### Non-image delivery (complete body)

- `Runner` returns `{:rendered, content_type, iodata(), CacheHeaders.t()}`. The
  `@type delivery()` is declared in **two** synced places —
  `runner.ex:22` and `sender.ex:26` — both gain the variant.
- A new `Sender.send_result/3` clause sends it with `send_resp/3`; a thin
  `Response.*` helper owns content-type + body and **does not** apply image
  `content-disposition` logic. `plug.ex` `request_result*/1` already matches
  `{:ok, _delivery}` generically, so no plug change is needed there.
- Render errors: `handle_processing_error/3` (`sender.ex:100-153`) has no clause for
  a `{:error, term()}` from `render/3`. Add a tag + clause; a render failure after a
  successful decode maps to **500** (server-side formatting failure).
- **Caching:** the **cache-key fold is mandatory** in Phase 1 (so deferring storage
  stays additive); **storing** rendered bodies is **optional** in Phase 1 (a complete
  body maps onto the existing `Cache.Entry` path; if deferred, open a follow-up). The
  streaming cache-sink (`source_session.ex:259`) is never involved.

### Telemetry

Rename the terminal span `[:encode]` → `[:render]` and carry a `representation`
metadata key (`:image` | `:json` | …). The image-encode span site is
`producer.ex:175`; the request-layer render emits its own `[:render]` span. Update
`ImagePipe.Telemetry.Logger` (`@group_span_events` subscription + a `message/3`
clause that still surfaces the outcome) and `docs/telemetry.md` in the same change.

### Plan validation

- `Plan.validate_shape` learns the `render` field (a `validate_render` clause + a
  `shape_error` member); default `:image_encode` passes trivially.
- **Empty-pipeline gate.** imgproxy `/info` has `pipelines: []`, which
  `Plan.validated_pipelines` rejects (`:empty_pipeline_plan`, `plan.ex:130`), at the
  pre-fetch gate `validate_prefetch_safe_plan` (`transform.ex:72`, called from
  `plug.ex:133`). Allow an empty pipeline **iff `plan.render` is a render selector**
  (i.e. `!= :image_encode`) — a **plan-shape** check, *not* a `requires` query, so
  the `Transform` boundary stays ignorant of `Output.Render` (a `transform → output`
  dep is forbidden). This is also correct for the future `:pixels`-on-empty-pipeline
  case (imgproxy info `palette`), which the depth-based predicate would wrongly
  reject. **No synthetic `:pixels`-rejection test in Phase 1.**

### Cache key / ETag

Fold the render selector into the **existing** `representation:` slot of
`Cache.Key.plan_material/2` (`key.ex:62-75`). The current `representation_data/0` is a
static `[version: …]` constant; it becomes `representation_data(plan.render)` (an
argument-taking private helper + its tests). The fold flows into both the cache key
and the input-derived ETag (`http_cache.ex`), separating `/info` from the image
render of the same source and preserving the 304-before-fetch path. The info plan's
`Output` mode must **not** be `:automatic`, so no spurious `Vary: Accept` is emitted
on the non-negotiated JSON response (an explicit render bypasses `Accept`
negotiation).

### imgproxy `/info` dispatch

In `parse_request/2`: detect the leading `/info` segment, peel it, verify the
signature on the remainder, parse source (no output-extension split),
parse-and-honor `expires`/`cachebuster` via the existing planner policy,
parse-and-ignore the display info-options, and emit
`%Plan.Render{renderer: :imgproxy_info, params: %{}}` with `pipelines: []`.

## Phase-1 scope

**Build:**

- `Plan.SourceInfo` (`format` atom, `width`, `height`, `orientation`, `byte_size`).
- `Plan.RenderContext` (only `info:`) and `Plan.render` field + `Plan.Render` spec +
  `validate_shape`/empty-pipeline branch.
- `Output.Render` behaviour (`requires/1` → `[:header]`, `render/3`).
- A request-layer (`Runner`) render branch that calls
  `Processor.fetch_decode_validate_source_with_source_format/3`, builds the context
  (straight-line header population), calls the renderer, returns `{:rendered, …}`.
- `Output.Render.ImgproxyInfo` (header fields → imgproxy JSON; **owns** the
  format/mime wire-spelling table).
- imgproxy `/info` dispatch (peel/verify/no-extension/honor-expires/ignore-display).
- `{:rendered}` delivery: `Runner` + `Sender` `delivery()` type, `Sender.send_result/3`
  clause + render error tag (500), `Response.*` complete-body helper (no image
  content-disposition).
- `[:render]` span + Logger + `docs/telemetry.md`.
- Wire-level Plug tests; `docs/imgproxy_support_matrix.md` (surface + stage/order +
  **behavioral** axes; remove the stale "no info endpoint" lines).

**Implemented imgproxy info field set:** `format`, `mime_type`, `width`, `height`,
`orientation`, `size` (best-effort).

**Do _not_ build** (additive later, each a field + need + satisfier branch):

- The `requires` union members `:pixels`/`{:detector,_}`/`:source_bytes`, the
  `normalize/1` implication graph, and the fold satisfier — straight-line `:header`
  only now.
- `exif` / `iptc` / `xmp` — ride `:header` (no extra stage) but need real
  metadata-block extraction + imgproxy naming; deferred as a **documented
  divergence** (see Divergence #1 — they are default-ON).
- `colorspace` / `bands` / `sample_format` / `alpha` / `pages_number` — imgproxy
  marks these *slow* and **default-OFF**; **excluded** (emitting them adds keys
  imgproxy omits by default).
- All pixel/detector/raw-byte fields (`detect_objects`, `classify`, `crop`,
  `palette`, `average`, `dominant_colors`, `blurhash`, `thumb/perceptual_hash`,
  `hashsums`).
- The imgproxy info-option **grammar** (per-field toggles). The options segment is
  parsed (for signature reconstruction) but display toggles are ignored;
  `expires`/`cachebuster` are honored.
- The `format:blurhash`/`format:lqip` output-format render path (roadmap).
- The detector-gate / cache-identity `or requires` plumbing (no Phase-1 caller).

**Out of scope (separate issues):** IIIF parser + `info.json` (Phase 2); the
blurhash/lqip `:pixels` renderers.

## Compatibility divergences (record in `docs/imgproxy_support_matrix.md`)

Cover **surface**, **stage/order**, *and* **behavioral** axes; remove the stale "no
info endpoint" lines; confirm the `IMGPROXY_INFO_PRESETS*` rows stay Missing
(info-option grammar deferred). Explicit divergences:

1. **Default response is a strict subset.** A bare `/info/SIG/plain/url` in imgproxy
   returns `size`, `format`/`mime_type`, `width`/`height`/`orientation`, **and** the
   default-ON `exif`/`iptc`/`xmp` blocks. ImagePipe Phase 1 **omits exif/iptc/xmp** —
   the *default, most-common* response diverges.
2. **`format`/`mime_type` spelling + detection.** Record imgproxy's exact spellings
   (`heic`/`image/heif`, `jxl`/`image/jxl`, …) and the HEIC↔AVIF
   loader-vs-magic-byte detection divergence.
3. **`size` omit-vs-download.** ImagePipe omits `size` on a length-less source;
   imgproxy downloads to compute it.
4. **Non-image / video source.** imgproxy returns a comma-format list for video;
   ImagePipe errors (415/422) — pin the status in a test.
5. **Excluded slow fields.** colorspace/bands/sample_format/alpha/pages_number not
   emitted (matches imgproxy defaults).

## Forward-compatibility notes (not built now)

- **`format:blurhash` / `format:lqip`** select `plan.render` via the imgproxy
  `format` option on a **full-pipeline** plan → `requires: [:pixels]`. The render
  runs in the request layer via `Processor.process_source/3` (fetch+decode+transform+
  materialize), hands `final_state.image` (plain Vix) to the renderer. `:blurhash`/
  `:lqip` are **neutral** renderers shared with TwicPics. **lqip may encode
  internally** (downscale → encode a tiny image → base64 → data-URI) — a render can
  call `Output.Encoder` as a sub-step. Additive: a `need` union member, a neutral
  renderer module, a parser `format`-value mapping.
- **IIIF `info.json`** is header-depth but `SourceInfo` serves only `width`/`height`;
  the rest is static constants + the **service base URI** + capability config. The
  render handler holds `conn`/`opts`, but "additive for IIIF" depends on threading
  that request/mount context into the renderer's inputs — settle the carrier shape
  (likely a field on `RenderContext`) when Phase 2 starts.
- **Detector gate + cache identity** will read render `requires` in addition to
  `Plan.detect_classes`/`face_assist?` when an info field first needs the detector
  (one helper, preserving the `face_assist?` branch).
- **Heavy-render cancellation** (above): wrap `:pixels` render compute in a monitored
  `Task` if disconnect-kill of CPU work matters.

## Boundaries

- `parser → plan` only: the imgproxy parser emits a neutral `Plan.Render` tag; never
  names a renderer module.
- `Plan.SourceInfo`, `Plan.Render`, `Plan.RenderContext` live under `Plan.*`; add to
  `Plan`'s `Boundary` exports **and** the exact-match list in
  `architecture_boundary_test.exs` (the export assertion is equality, not subset).
- `Output.Render` behaviour + renderers live under `Output.*` (add to `Output`
  exports), depending only on `Plan.*` (+ external Vix for the future `:pixels`
  image) — **not** on `Transform.*`.
- The render branch runs in `Request.*` (`Runner`), which already deps on
  `Output`/`Transform`/`Source`; it reaches decode/materialize through `Processor`
  (the `Transform` facade), never a concrete op module.

## Testing

- Wire-level `ImagePipe.call/2` for a signed `/info` URL: 200 + `application/json` +
  the field set; orientation-adjusted dims for an EXIF 5–8 source; a HEIC source
  yields exactly `"format":"heic","mime_type":"image/heif"` (not just "TIFF works").
- Source-safety: a bad-signature / bad-source `/info` request returns **before** any
  source fetch; an expired `/info` URL returns 404.
- A non-image (e.g. video) source returns a clean 415/422.
- No `Vary: Accept` on the JSON response.
- Empty-pipeline render plan validates (no synthetic `:pixels` plan).
- `size` degradation: a length-less source omits `size` rather than downloading.
- Telemetry: `[:render]` span with `representation` metadata; Logger renders it.

## Open questions resolved

- **Invocation site:** the **request layer** (`Runner`) via `Processor.*` —
  **not** the producer/`SourceSession`. Renders never touch `PreparedStream`/
  `Resolved`/the cache sink (no neutralization).
- **Delivery:** complete-body `{:rendered}`.
- **Plan model:** minimal `Plan.render` selector; `plan.output` untouched.
- **`requires`:** `need :: :header` now; union widens at first `:pixels` caller; fold
  is the documented forward generalization, not Phase-1 code.
- **`byte_size`:** request-layer-filled from `Source.Response`/`File.stat`, not the
  header image; omit when absent (download-fallback is a divergence).
- **Field set:** `format`/`mime_type`/`width`/`height`/`orientation`/`size`;
  exif/iptc/xmp deferred (documented divergence); colorspace group excluded.
- **MIME/format spellings:** owned by the `ImgproxyInfo` renderer (imgproxy wire
  strings), not `ImagePipe.Format`.
- **Empty-pipeline gate:** plan-shape predicate (`plan.render` is a render selector).
