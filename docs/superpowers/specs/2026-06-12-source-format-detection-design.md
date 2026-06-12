# Up-front source format detection (magic bytes), independent of libvips

Issue: #170 — *Source: up-front image format detection (magic bytes + ct/ext
hints), independent of libvips.*

## Summary

Detect the source image format **before** libvips opens the bytes, from a bounded
header peek of magic bytes (plus a lightweight structural scan for SVG, which has
no fixed magic). The detector becomes authoritative for the format where magic is
unambiguous, gates known-unsupported formats before any libvips decode, and falls
back to the existing libvips classification only when magic cannot decide.

This is the low-risk half of "read headers ourselves": fixed-offset/structural
sniffing over a small prefix, no decode, no attacker-controlled binary parsing.
Reading dimensions/EXIF from the header is **explicitly out of scope** (issue
*Related* section) — that is a separate, security-sensitive follow-on.

**Scope decisions taken during brainstorming (2026-06-12):**

1. **Detector role:** authoritative where magic is confident **+** pre-decode
   gate, with libvips as the `:unknown` fallback *and* the validator. Not a pure
   authoritative allowlist.
2. **ct/ext hints:** **not wired** in this issue. Magic bytes + structural SVG
   only. Their sole behavioral effect in imgproxy's `imagetype` is RAW-vs-TIFF
   disambiguation, which is niche, non-regressing today, and unreliable via
   extension alone. Deferred to a separate follow-on that wires **content-type
   and extension together** (content-type is the more reliable signal and is the
   one that earns the `Source.Response` plumbing).
3. **SVG:** lightweight bounded structural scan, not a full XML tokenizer.
4. **Vocabulary:** detect the supported superset **plus** named rejects
   (gif/bmp/ico/svg), so unsupported formats fail with a precise family instead
   of a generic `:unknown`. Includes a JP2 detector that imgproxy's `imagetype`
   lacks.

## Ground truth

imgproxy's `imagetype` package (local checkout `/Users/hlindset/src/imgproxy/imagetype/`):
a priority-ordered detector registry over an `io.LimitReader(re, 32KB)` peek;
rewind between detectors; first non-`Unknown` wins. Magic-byte table with a `?`
wildcard matcher (`RIFF????WEBP`, `????ftypavif`, eight HEIC brands), then a TIFF
detector (priority 80, defers to a RAW ext/MIME list), then SVG (priority 100, XML
tokenizer for an `<svg>` start element). Called from the download path with the
HTTP `Content-Type` and the lowercased URL-path extension as hints
(`imagedata/factory.go`). imgproxy's own caveat: 2-byte magic is ambiguous for
naked JXL (`\xff\x0a`) and ICO — "can't be 100% sure until we fully decode."

## Why this is *input conditioning*, not a transform

Per the repo's transform guidelines, a concern that is (a) not a user-requested
transform and (b) sourced entirely from runtime image inspection — the bytes,
which no `Plan.Operation` can see — is **not** a `Plan.Operation`. It is fixed
pipeline preamble or self-managing state, like decode access mode, shrink-on-load
planning, and EXIF auto-orient. Format detection is exactly this category, so it
lives as preamble inside the decode path, not as an operation and not on `Plan`.

## Architecture

### Placement

Detection slots into `ImagePipe.Request.Processor.decode_validate_source_response/3`
([lib/image_pipe/request/processor.ex](../../../lib/image_pipe/request/processor.ex)),
after `seekable_input` (so bytes are available) and **before** the libvips header
open:

```
seekable_input            -> {:buffer, binary} | {:path, path}     (existing)
peek_bytes(input)         -> first <=32KB binary prefix            (NEW)
Format.Detector.detect/1  -> detected format atom (pure)           (NEW)
gate(detected)            -> reject family => error, no libvips     (NEW)
libvips header open        (access: :random, fail_on: :error)      (existing)
resolve_source_format      -> authoritative | libvips codec | fallback (NEW)
... original_dims, validate_original_pixels, DecodePlanner, 2nd open ... (existing)
```

The stream is already fully drained by `seekable_input` today (existing
architecture; the early-abort-download optimization belongs to #263 and is out of
scope). "Gate before libvips" therefore means **libvips never decodes a rejected
format** — the security/loader-independence benefit — not that we avoid the
download.

### Component 1 — `ImagePipe.Format.Detector` (new, pure)

Lives under the existing `ImagePipe.Format` boundary (`deps: []`, pure). The
format vocabulary already lives in `Format`; a dependency-free byte classifier
fits there. Add `exports: [Detector]` to the `Format` boundary so `Request` (which
already deps `Format`) can call it.

Public API:

```elixir
@type detected() ::
        :jpeg | :png | :webp | :gif | :bmp | :ico | :svg
        | :tiff | :heif | :avif | :jpeg_xl | :jpeg2000 | :unknown

@spec detect(binary()) :: detected()
def detect(peek) when is_binary(peek)
```

A richer vocabulary than `Format.source_format()` on purpose, so unsupported
formats reject with a named family.

**Magic table** (ported from imgproxy, plus JP2; `:any` marks a wildcard byte):

| Format    | Signature(s) |
| --------- | ------------ |
| jpeg      | `FF D8` |
| png       | `89 50 4E 47 0D 0A 1A 0A` |
| webp      | `52 49 46 46 ?? ?? ?? ?? 57 45 42 50` (`RIFF????WEBP`) |
| gif       | `47 49 46 38 ?? 61` (`GIF8?a`) |
| bmp       | `42 4D` (`BM`) |
| ico       | `00 00 01 00` |
| jpeg_xl   | `FF 0A` (codestream) · `00 00 00 0C 4A 58 4C 20 0D 0A 87 0A` (container) |
| heif      | `?? ?? ?? ?? 66 74 79 70 <brand>` for brand ∈ {heic, heix, hevc, heim, heis, hevm, hevs, mif1} |
| avif      | `?? ?? ?? ?? 66 74 79 70 61 76 69 66` (`????ftypavif`) |
| tiff      | `49 49 2A 00` (LE) · `4D 4D 00 2A` (BE) — plain magic, no RAW skip |
| jpeg2000  | `00 00 00 0C 6A 50 20 20 0D 0A 87 0A` (JP2 signature box) · `FF 4F FF 51` (J2K codestream) |

The `00 00 00 0C …` JXL-container, JP2-box, and `00 00 01 00` ICO prefixes all
diverge by the 3rd/4th byte; the signature set is mutually exclusive across the
table, so a single ordered pass with first-match-wins is deterministic.

**Wildcard matcher** (ports imgproxy's `hasMagicBytes`): a signature is a list of
`byte | :any`; it matches when `byte_size(peek) >= length(sig)` and every
non-`:any` position is byte-equal. `:any` matches any byte.

**Order:** try all magic signatures (first match wins) → if none match, run the
SVG structural scan → else `:unknown`. SVG runs last because magic is cheaper and
a file with real magic must never be re-interpreted as SVG.

### Component 2 — SVG structural scan (inside `Detector`)

Bounded, not a full XML parser. Over the peek:

1. Strip a leading UTF-8 BOM (`EF BB BF`) if present.
2. Skip leading whitespace.
3. Repeatedly skip XML-prolog constructs and inter-construct whitespace:
   - `<? … ?>` processing instruction / XML declaration,
   - `<!-- … -->` comment,
   - `<!DOCTYPE … >` / `<! … >` markup declaration, **handling a `[ … ]`
     internal subset** (skip to the matching `]`, then to the closing `>`) — the
     one genuinely fiddly case, since the internal subset can contain `>`.
4. Test whether the next token opens an element whose local name is `svg`:
   `<` then an optional `prefix:` then `svg` then a delimiter
   (whitespace, `>`, or `/`). Match → `:svg`.
5. Otherwise (a different start tag, malformed input, or peek exhausted) →
   not SVG; detection yields `:unknown`.

**Why the scan is low-stakes — it can never cause a wrong *accept*:**
- A false negative → `:unknown` → libvips → `svgload` → still rejected as
  unsupported.
- A false positive → rejected as `:svg` instead of `:unknown` → still rejected.

ImagePipe rejects SVG either way, so the scan's *only* real job is catching
genuine SVGs early so **libvips' `svgload` never parses attacker-controlled XML**
(XML-bomb / external-entity surface). It therefore biases toward catching SVG and
may punt to `:unknown` on anything genuinely ambiguous, but it should be thorough
enough on real-world SVG prologs (BOM, declaration, DOCTYPE, comments,
namespace-prefixed root) to keep libvips out of the XML.

### Component 3 — gate & source-format resolution (in `Processor`)

Two small steps around the existing libvips open.

**`gate(detected)` — before the open:**

```
detected ∈ {:gif, :bmp, :ico, :svg} -> {:error, {:unsupported_source_format, detected}}
otherwise                            -> :ok
```

Rejected formats never reach libvips. The error family type on
`ImagePipe.Request.SourceFormat` widens from `:svg | :unknown` to also include
`:gif | :bmp | :ico`. `ImagePipe.Response.Sender` already handles
`{:unsupported_source_format, _family}` generically
([lib/image_pipe/response/sender.ex:127](../../../lib/image_pipe/response/sender.ex)),
so no sender change.

**`resolve_source_format(detected, header_image)` — after the open:**

```
detected ∈ {:jpeg, :png, :webp, :tiff, :jpeg2000, :jpeg_xl}
    -> {:ok, detected}                       # authoritative; skip SourceFormat.from_image

detected ∈ {:avif, :heif}
    -> SourceFormat.from_image(header_image)  # libvips supplies the precise codec
       (fall back to `detected` only if libvips cannot classify the loader)

detected == :unknown
    -> SourceFormat.from_image(header_image)  # existing behavior, unchanged
```

`ImagePipe.Request.SourceFormat.from_image/1` is **kept** as the `:unknown`
fallback and as the avif-vs-heif codec oracle. libvips also remains the validator:
a wrong confident detection fails the subsequent open → `{:decode, _}` → 415,
exactly as today.

### Component 4 — `peek_bytes/1` (in `Processor`)

```
{:buffer, binary} -> binary_part(binary, 0, min(byte_size(binary), @peek_bytes))
{:path, path}     -> read first @peek_bytes of the file
```

`@peek_bytes 32 * 1024` (matches imgproxy's `maxDetectionLimit`). For the buffer
case the slice is a sub-binary reference (no copy). For the path case, read up to
32KB via `File.open/2` + `IO.binread/2` (or `:file.read/2`); a read error is
mapped consistently with the existing decode/source error handling (the libvips
open would fail on the same unreadable input). The peek read does not consume or
seek the libvips open — libvips opens the path/buffer independently — so the
seekable-decode path (#142) is untouched.

## Confidence analysis (does this detect every *compatible* input?)

| Supported format        | Magic                    | Confidence |
| ----------------------- | ------------------------ | ---------- |
| png                     | 8-byte sig               | Strong |
| webp                    | `RIFF????WEBP` (12B)     | Strong |
| jpeg2000                | JP2 box (12B) / `FF4FFF51` | Strong |
| jpeg_xl (container)     | 12-byte sig              | Strong |
| jpeg                    | `FF D8` (2B)             | Reliable (SOI marker is universal) |
| tiff                    | `II*\0` / `MM\0*` (4B)   | Reliable for real TIFF (RAW→tiff is the documented ct/ext gap) |
| jpeg_xl (naked codestream) | `FF 0A` (2B)          | Weak — self-correcting |
| avif / heif             | `????ftyp<brand>`        | Family strong; avif-vs-heif sub-split weak |

Two soft spots, neither a real problem:

- **Naked JXL (`FF 0A`):** a false positive → authoritative `:jpeg_xl` →
  `jxlload` open fails → 415 (libvips validates); a false negative → `:unknown` →
  libvips fallback. No wrong-accept survives, no regression; correct for genuine
  JXL.
- **AVIF vs HEIC:** magic reads the `ftyp` *brand*, not the codec; a generic
  `mif1`-brand AVIF would read as `:heif`. imgproxy has the identical imprecision
  (it maps `mif1` → HEIC). Verified that **nothing in the codebase branches on
  `source_format` `:avif` vs `:heif`**: in `Output.Policy`, `@passthrough_source_formats`
  is `[:jpeg, :png]`; avif and heif both fall to the same `:needs_final_image_alpha`
  branch, and the default output format is chosen by `Accept`-header negotiation
  (`Output.Negotiation.modern_candidates/2`), not by the source format. So the
  label is telemetry-only today. Component 3 nonetheless takes the avif/heif codec
  from libvips (header is open anyway), keeping the label exactly as precise as
  today at zero extra cost.

Net: every compatible format is confidently **accepted or rejected**; anything
magic cannot decide falls to `:unknown` → libvips (no regression); the one
distinction magic genuinely cannot make (ISOBMFF codec) is supplied by the
already-paid header open.

## Deliberate divergences from imgproxy

For `docs/imgproxy_support_matrix.md` (stage axis + "Diverges" notes):

1. **`:unknown` → libvips fallback**, where imgproxy hard-rejects `Unknown`.
   ImagePipe stays as capable as the libvips build (this is current behavior);
   detection is authoritative-where-confident + gate, not a hard allowlist.
2. **No ct/ext → no RAW-vs-TIFF skip.** A RAW file with TIFF magic detects as
   `:tiff` (= today's behavior). Documented gap; deferred to a content-type +
   extension follow-on.
3. **JP2 detection added** (imgproxy's `imagetype` has none); incomplete JP2
   variants fall to `:unknown` → libvips `jp2kload`.
4. **Vocabulary maps to ImagePipe atoms** (`:heif` not `heic`, `:jpeg_xl` not
   `jxl`, `:jpeg2000`).

## Boundaries

- New module under the `Format` boundary; add `exports: [Detector]`.
- `Format` stays `deps: []` (the detector is pure).
- `Request` already deps `Format`; the gate/resolve logic lives in `Request`
  (`Processor` + `SourceFormat`), which may reference `Format.Detector` and the
  existing `SourceFormat`. No request code references concrete transform modules,
  so the architecture boundary tests are unaffected.

## Telemetry

Detection **surfaces in telemetry** (firm decision). The detected format is
product-neutral and non-sensitive, so it is emitted, and the opt-in default
Logger renders it.

- **Event:** add to the existing `[:source, :fetch_decode]` stop metadata rather
  than a new span — detection is a cheap pure function, not a stage worth its own
  span.
- **Fields:**
  - `detected_source_format` — the raw `Detector.detect/1` output (e.g. `:avif`,
    `:gif`, `:unknown`).
  - `source_format_resolution :: :detected | :libvips_codec | :libvips_fallback`
    — how the final `source_format` was decided (authoritative magic / libvips
    avif-vs-heif codec / `:unknown` libvips fallback).
- **Error path matters most.** `detected_source_format` must be present on the
  reject path too (gif/bmp/ico/svg fail *before* the open), so an observer can
  see *why* a request was rejected. On that path the family in
  `{:unsupported_source_format, family}` **is** the detected format, so
  `fetch_decode_stop_metadata/1` can derive the field from either the success
  result (carry a new field) or the error tuple. Both the `:stop` (success) and
  the unsupported-format outcome carry the field.
- **Logger:** because this adds metadata to an *existing* event (no new/renamed
  event), the default Logger needs a rendering change only, not a new
  subscription. `ImagePipe.Telemetry.Logger` must render the detected format on
  the source fetch/decode line **while still surfacing the outcome** (don't let a
  prettier message swallow `:result`/error state), and escalate level on the
  reject/fallback signal if appropriate (`level_for/3`). Update `docs/telemetry.md`
  and add a `logger_test.exs` assertion for the rendered line.

## Testing

**Detector unit tests** (byte literals — no committed source images needed):

- One per magic signature, including wildcard cases: webp size bytes, every HEIC
  brand, avif, both JXL forms, both JP2 forms, TIFF LE and BE.
- gif / bmp / ico classification (→ reject families).
- SVG structural-scan cases: leading whitespace, UTF-8 BOM, `<?xml … ?>`
  declaration, `<!DOCTYPE …>` **with a `[ … ]` internal subset**, comments,
  namespace-prefixed root (`<svg:svg`), and negatives (HTML, plain text) →
  `:unknown`.
- Negatives: truncated/empty input, random bytes → `:unknown`.

**Property tests** (StreamData):

- Confident detection is **prefix-stable**: appending arbitrary bytes to a
  signed prefix does not change the detected format.
- **Peek-vs-full agreement**: detection over the bounded 32KB peek equals
  detection over the full input for the magic formats.

**Wire-level tests** (`ImagePipe.call/2`, the key security assertions):

- A gif / bmp / ico / svg source body is rejected with
  `{:unsupported_source_format, family}` **with the libvips open never invoked** —
  asserted via the injectable `image_open_module` / `buffer_loader` seam in
  `Processor`. Reject-path bodies can be **synthetic magic-prefixed blobs** served
  through the existing source stub (they are never decoded), so **no new
  `SourceInventory` entries** are required.
- A supported format (existing fixtures) resolves `source_format` from the
  detector (authoritative path).
- The avif/heif codec split still comes from libvips (existing HEIF/AVIF fixtures
  continue to classify correctly).
- `:unknown` → libvips fallback is covered at the unit level (detector returns
  `:unknown` → `resolve_source_format` calls `SourceFormat.from_image`); add a
  wire test only if a clean `:unknown`-but-libvips-loadable fixture is convenient.

No new source images are anticipated; if any are added, update
`SourceInventory` and the drift test in the same change (per AGENTS.md).

## Docs to update in the same change

- `docs/imgproxy_support_matrix.md`: add an input-format-detection preamble note
  to the processing-pipeline/stage section, plus the four divergences above.
  Confirmed by the compatibility reviewer in the plan-review cycle.
- `docs/telemetry.md` + `ImagePipe.Telemetry.Logger`: render the detected format
  on the source fetch/decode line, with a `logger_test.exs` assertion (see
  Telemetry).

## Out of scope (explicit)

- Reading dimensions / EXIF orientation from the header (the harder, security-
  sensitive follow-on; IFD/ISOBMFF offsets can exceed a bounded peek). Conservative
  bounded dimension sniffing for the fixed-offset/bounded-scan set
  (PNG/GIF/BMP/ICO/WebP/JPEG), for early pixel-rejection, is scoped separately in
  #264; the libvips header open remains the dimension source here.
- ct/ext hint wiring and RAW-vs-TIFF disambiguation (separate follow-on, with
  content-type).
- Early-abort-download / streaming-source overlap (#263).
- Expanding the set of *supported* source formats (gif/bmp/ico stay rejected;
  detection just names them. If support is added later, move the atom from the
  reject set into `Format.source_formats/0`).

## Review cycle (per AGENTS.md)

Before implementation, run a parallel subagent review of this spec with disjoint
lenses. Because the change has observable imgproxy-parity behavior (format
spellings + classification + which formats reject before decode), **at least one
reviewer must focus on observable compatibility against the local imgproxy
`imagetype` source** as ground truth. Other lenses: Elixir/boundary architecture,
request-safety boundaries, and test adequacy. Apply accepted feedback and commit
the reviewed spec before writing the implementation plan.
