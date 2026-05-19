# Input format and SVG policy design

## Context

ImagePlug currently fetches source bytes, opens them with `Image.open/2`, and
then reads the decoded image's `vips-loader` metadata to infer a narrow source
format. The current mapping in `ImagePlug.Request.Processor` recognizes JPEG,
PNG, WebP, and AVIF-style HEIF loader output.

That mapping currently reuses output format names for source detection. The new
policy should separate source format families from output formats. For example,
HEIC and AVIF can both arrive through libvips HEIF loading, but ImagePlug only
supports AVIF as an output format today.

That means the real pre-decode input policy is partly delegated to the local
`image` and libvips runtime. The project already depends on `image` 0.67.0, and
that dependency can route SVG-looking binaries through libvips SVG loading.
ImagePlug hasn't designed SVG passthrough, SVG sanitizing, SVG rendering limits,
or cache behavior.

The imgproxy compatibility research matters here, but it shouldn't define the
core model. Imgproxy supports a broader source-format set and treats SVG as a
special source format. It can sanitize SVG, skip normal processing for omitted
output, or render SVG as raster output when configured. ImagePlug shouldn't copy
those behaviors implicitly. The imgproxy parser should translate URL grammar and
defaults into ImagePlug-owned policy when ImagePlug supports those surfaces.

## Goal

Define a small product-neutral policy for this implementation slice:

- ImagePlug rejects SVG input before normal image decode.
- Raster input support is explicit and limited to formats ImagePlug names.
- libvips remains responsible for raster decoding and validation.
- Omitted output doesn't require source-format round trip.
- A later SVG design can add support without changing the request
  boundary again.

## Non-goals

This slice doesn't add SVG passthrough, SVG sanitizing, SVG rendering,
`skip_processing`, raw response delivery, PDF, PSD, RAW, video,
origin metadata propagation, or imgproxy Pro compatibility.

This slice also doesn't build a complete ImagePlug raster file sniffer. For
raster formats, libvips already performs import detection. ImagePlug shouldn't
duplicate that logic unless a later feature needs format-specific behavior
before decode.

## Origin metadata

This slice doesn't change `ImagePlug.Source.Response` to carry content type,
filename, or extension hints.

Those hints may be useful later, especially for imgproxy compatibility work.
They aren't needed for this SVG rejection and raster-source policy. Keeping them
out avoids eager HTTP/S3 fetch changes and keeps the source adapter contract
stable for this PR.

## SVG policy

ImagePlug rejects SVG before `Image.open/2`.

The pre-decode check should be narrow and bounded. It should identify obvious
SVG documents from an initial prefix and return an unsupported source format
error before libvips sees the stream. It shouldn't attempt full XML validation
or sanitizing.

The detector should reject these cases inside the bounded prefix:

- optional UTF-8 byte-order mark and leading ASCII whitespace before `<svg`
- XML declarations before an SVG root
- XML comments or document type declarations before an SVG root
- case-insensitive `<svg` and namespace-prefixed SVG root tags

If the prefix is XML-looking but inconclusive inside the bound, reject it rather
than passing it to libvips. The point is to keep implicit SVG rendering out of
this slice.

The detector must not buffer the whole source. If it consumes a prefix from the
stream, it must pass that prefix to decode first. Accepted raster inputs still
decode from the original byte sequence.

This policy is stricter than imgproxy's default SVG behavior. ImagePlug doesn't
yet have an SVG sanitizer, passthrough response path, SVG
size policy, or cache representation for SVG output. Rejecting SVG is the
smallest behavior that removes the current accidental SVG rendering surface.

## Raster input policy

For raster inputs, ImagePlug should let `Image.open/2` and libvips decode the
image. After decode, ImagePlug reads the loader metadata and maps it to a named
source format family.

Accepted source format families for this slice:

- `:jpeg`
- `:png`
- `:webp`
- `:heif` for AVIF, HEIC, and HEIF-family inputs
- `:tiff`
- `:jpeg2000`
- `:jpeg_xl`

If decode succeeds but the loader maps to a source format outside that set,
ImagePlug returns unsupported source format behavior. If ImagePlug can't map the
loader, the request fails instead of falling back to an implicit source-format
round trip.

Documentation should list these inputs as unsupported in this slice:

- SVG
- GIF
- ICO
- BMP
- PDF, PSD, RAW, and video inputs

The local runtime may decode some of those formats. That doesn't make
them part of ImagePlug's public input contract.

Runtime support can still vary by libvips build. If a deployed runtime can't
decode an accepted source family, ImagePlug returns the existing decode failure.
The public contract is that ImagePlug permits the source family when libvips can
decode it.

## Omitted output

The current automatic output path can fall back to the decoded source format
when negotiation selects no AVIF/WebP `Accept` candidate. That couples omitted
output to source-format round trip.

This slice should shift omitted output to a preferred-output policy:

1. If `Accept` negotiation selects an enabled modern format, use it.
2. Otherwise choose from configured preferred output formats.
3. Only choose formats ImagePlug can encode.

The default preferred output list should stay inside the current output set. A
reasonable first default is `[:png]`. That avoids alpha loss while #50 and an
alpha-aware JPEG/PNG fallback remain separate work. AVIF and WebP still win when
the request `Accept` header and `auto_avif` or `auto_webp` options permit them.

Don't add GIF to the default preferred list until ImagePlug implements GIF output.
Don't copy imgproxy's `IMGPROXY_PREFERRED_FORMATS` name into core.

If this slice makes preferred output configurable, the normalized preferred list
must enter automatic-output cache key data. Otherwise different configurations
can share a cache key while producing different fallback output formats.

Issue #50 is adjacent but remains a separate slice. This design creates the
preferred-output fallback that #50 can use, but it doesn't define wildcard-only
`Accept` behavior or alpha-aware JPEG/PNG fallback. It also doesn't define a
configuration switch for deployments that want AVIF/WebP from non-informative
`Accept` headers.

## Runtime flow

Cache lookup stays before source fetch for cacheable requests:

1. Parse request into `ImagePlug.Plan`.
2. Check the plan.
3. Resolve the source identity.
4. Look up the cache when the resolved source is cacheable.
5. Resolve explicit output and modern automatic candidates before source fetch
   when the current architecture can do so.
6. On cache miss, fetch source bytes.
7. Reject SVG from a bounded source prefix before normal decode.
8. Decode accepted raster input with `Image.open/2`.
9. Check decoded pixel limits with `max_input_pixels`.
10. Map the decoded loader to an accepted source format family.
11. Resolve any remaining automatic output fallback from preferred output policy.
12. Execute transforms, encode, send, and cache only successful encoded
    responses.

Invalid parser and planner requests still return before source fetch or cache
lookup. Cache hits don't fetch source bytes and don't run input detection.

## Boundary placement

Product-neutral policy belongs in core modules:

- SVG pre-decode rejection can live under a source/input helper owned by core,
  not under the imgproxy parser.
- Source-format mapping and accepted source-format policy should stay outside
  `ImagePlug.Parser.Imgproxy`.
- Omitted-output fallback belongs under `ImagePlug.Output.Policy`.
- Automatic-output cache key data must include any preferred-output fallback
  configuration that can change the selected output format.

Imgproxy-specific URL grammar, aliases, `@extension`, compatibility docs, and
future compatibility defaults remain under `ImagePlug.Parser.Imgproxy` or a
provider compatibility layer.

Request, source, and response code must continue to dispatch through generic
transform/runtime API calls. They shouldn't reference concrete transform operation
modules.

## Error behavior

SVG and unsupported decoded source formats should surface as unsupported source
image failures. At the Plug boundary, the response should stay deterministic and
client-facing without exposing filenames, source URLs, signatures, parser
structs, or loader internals.

Telemetry metadata should stay low-cardinality. It can report result classes
such as decode error, input limit error, or unsupported source format. It should
not emit source URLs, filenames, or raw content types by default.

## Tests

Focused tests should cover:

- ImagePlug rejects SVG-looking input before calling the image open module.
- Accepted raster fixtures still decode and process normally.
- Source formats that libvips can decode but ImagePlug doesn't accept fail for
  both explicit output and omitted output requests.
- Accepted non-output source families such as HEIF, TIFF, JPEG 2000, and JPEG XL
  normalize to supported output formats.
- Omitted output without a modern `Accept` candidate uses preferred output
  fallback.
- Automatic-output cache keys include the normalized preferred-output fallback
  policy when that policy is configurable.
- SVG prefix handling covers split chunks, prefix replay for accepted raster
  input, body-limit accounting after peeking, stream errors after the prefix,
  and early cancellation when ImagePlug rejects SVG.
- Imgproxy wire-level behavior rejects SVG before transform execution and still
  preserves cache-before-fetch behavior for cacheable requests.

Documentation updates should cover:

- Current accepted input formats.
- Explicit SVG rejection.
- Known unsupported imgproxy source formats.
- Source formats versus output formats.
- The distinction between imgproxy `@extension` as requested output and
  ImagePlug's source-format detection after decode.

## Open follow-up

Future SVG support needs its own design. That design should decide between
sanitized passthrough, SVG rendering, or both. It also needs source byte limits,
SVG canvas limits, cache key data, response content type behavior, and tests for
unsafe SVG constructs.
