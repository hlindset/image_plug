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

- ImagePlug rejects SVG input after decode identifies an SVG loader and before
  transforms or output encoding.
- Raster input support is explicit and limited to formats ImagePlug names.
- libvips remains responsible for raster decoding and validation.
- Omitted output has a narrow decoded fallback for accepted source-only formats.
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

This slice doesn't add runtime output write-capability probing. Output fallback
uses ImagePlug's static output format set for this PR.

This slice doesn't add a pre-decode SVG detector. That would require bounded
stream peeking, prefix replay, body-limit accounting changes, and cache policy
work. The first implementation only needs to stop accidental SVG processing in
ImagePlug's transform and output path. If a later need says libvips must never
parse SVG bytes, that should be a separate design and implementation slice.

## Origin metadata

This slice doesn't change `ImagePlug.Source.Response` to carry content type,
filename, or extension hints.

Those hints may be useful later, especially for imgproxy compatibility work.
They aren't needed for this SVG rejection and raster-source policy. Keeping them
out avoids eager HTTP/S3 fetch changes and keeps the source adapter contract
stable for this PR.

## SVG policy

ImagePlug rejects SVG when decoded loader metadata maps to an SVG source
family.

The rejection happens after `Image.open/2` and before transform execution,
output selection, or output encoding. This keeps SVG out of ImagePlug's image
delivery behavior without adding a stream sniffer to the source boundary.

This policy is stricter than imgproxy's default SVG behavior. ImagePlug doesn't
yet have an SVG sanitizer, passthrough response path, SVG
size policy, or cache representation for SVG output. Rejecting SVG is the
smallest behavior that removes the current accidental SVG rendering surface.

## Raster input policy

For raster inputs, ImagePlug should let `Image.open/2` and libvips decode the
image. After decode, ImagePlug reads the loader metadata and maps it to a named
source format family.

Source-family validation runs for every request mode, including explicit output
requests such as `f:png`. It runs after decode and before transform execution.
It should run before decoded pixel-limit checks so unsupported-but-decodable
sources fail as unsupported source formats, not as input limit failures.

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

The implementation should keep loader mapping explicit. Tests should cover the
current loader prefixes for JPEG, PNG, WebP, HEIF-family, TIFF, JPEG 2000, and
JPEG XL inputs. Fixture tests for optional formats may skip when the local
libvips build lacks read support, but mapping tests shouldn't depend on optional
format support.

## Omitted output

The current automatic output path can fall back to the decoded source format
when negotiation selects no AVIF/WebP `Accept` candidate. That couples omitted
output to source-format round trip. That works for JPEG, PNG, WebP, and AVIF
because those source names are also ImagePlug output formats. It doesn't work
for accepted source-only families such as HEIF, TIFF, JPEG 2000, and JPEG XL.

This slice should add only the fallback needed for those source-only inputs:

1. If `Accept` negotiation selects an enabled modern format, use it.
2. If the decoded source format is one of ImagePlug's output formats, keep the
   current source-format fallback.
3. If ImagePlug accepts the decoded source format as input but doesn't expose it
   as an output format, choose from ImagePlug's static output set:
   - `:png` when the decoded image or planned output needs alpha preservation.
   - `:jpeg` for ordinary opaque still images.

The alpha check can use decoded image properties and existing plan behavior that
can introduce transparency, such as padding or extension. It shouldn't flatten
or inspect encoded bytes just to choose the fallback.

Don't add GIF to the default preferred list until ImagePlug implements GIF output.
Don't copy imgproxy's `IMGPROXY_PREFERRED_FORMATS` name into core.

This slice shouldn't add a preferred-output configuration option. Issue #50 is
adjacent but remains a separate slice. This design doesn't define wildcard-only
`Accept` behavior, a configurable preferred-format list, JPEG XL output
negotiation, or a switch for deployments that want AVIF/WebP from
non-informative `Accept` headers.

## Runtime flow

Cache lookup stays before source fetch for cacheable requests:

1. Parse request into `ImagePlug.Plan`.
2. Check the plan.
3. Resolve the source identity.
4. Build cache key data from resolved source identity, canonical plan fields,
   configured vary inputs, and normalized `Accept` data for automatic output.
5. Look up the cache when the resolved source is cacheable.
6. Resolve explicit output and modern automatic candidates before source fetch
   when the current architecture can do so.
7. On cache miss, fetch source bytes.
8. Decode input with `Image.open/2`.
9. Map the decoded loader to a source format family.
10. Reject SVG and unsupported decoded source families.
11. Check decoded pixel limits with `max_input_pixels`.
12. Resolve any remaining automatic output fallback from source format and
    decoded output properties.
13. Execute transforms, encode, send, and cache only successful encoded
    responses.

Invalid parser and planner requests still return before source fetch or cache
lookup. Cache hits don't fetch source bytes and don't run input detection.

## Boundary placement

Product-neutral policy belongs in core modules:

- Source-format mapping and accepted source-format policy should stay outside
  `ImagePlug.Parser.Imgproxy`. The decoded loader mapping can live under
  `ImagePlug.Request` or behind a narrow core helper used by request processing.
- Omitted-output fallback belongs under `ImagePlug.Output.Policy` or a narrow
  helper owned by `ImagePlug.Output`.
- Source identity and cache lookup stay under the existing request/cache
  boundaries. This slice doesn't add an input policy marker to cache key data
  because detection still happens after cache miss and successful encoded
  responses remain keyed by source identity and output-varying fields.

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

Use an internal error reason shaped like `{:unsupported_source_format, family}`.
At the Plug boundary, route that to the same response class as unsupported
decode input: status `415` with the existing unsupported image response body.

Telemetry metadata should stay low-cardinality. It can report result classes
such as decode error, input limit error, or unsupported source format. It should
not emit source URLs, filenames, or raw content types by default.

## Tests

Focused tests should cover:

- ImagePlug rejects decoded SVG loader metadata before transform execution and
  output encoding.
- Accepted raster fixtures still decode and process normally.
- Source formats that libvips can decode but ImagePlug doesn't accept fail for
  both explicit output and omitted output requests.
- Accepted source families that aren't output format atoms, such as HEIF, TIFF,
  JPEG 2000, and JPEG XL, resolve omitted output through the JPEG/PNG fallback.
- Omitted output without a modern `Accept` candidate keeps source-format
  fallback for JPEG, PNG, WebP, and AVIF sources.
- Omitted output without a modern `Accept` candidate uses JPEG for opaque
  source-only families and PNG when alpha matters.
- Cache lookup still happens before source fetch for cacheable requests.
- Imgproxy wire-level behavior rejects SVG before transform execution.

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
