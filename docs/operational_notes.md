# Operational notes

ImagePlug verifies Imgproxy signatures and parses Imgproxy path options before
fetching source bytes. Invalid signatures return `403`, and invalid processing
requests return `400`, both without source traffic.

Parser and plan validation finish before source resolution, cache lookup, or
fetch. Source resolution finishes before cache lookup. Requests eligible for
caching look up the cache before source fetch and decode, so fetch and decode run
only on a cache miss or when the resolved source has `cache: :skip`.

HTTP and S3 source fetches use non-bang Req calls with bounded redirects and
receive timeouts. ImagePlug reads the source format from the decoded image
rather than trusted HTTP headers. Configure byte and decode limits with
`:max_body_bytes` and `:max_input_pixels`.

Built-in HTTP and S3 `req_options` are host-owned behavior. They must not vary
source bytes for the same resolved identity. Byte-selecting request options need
URI/object revision material, `cache: :skip`, or a custom adapter identity
field.

S3 `buckets` is a map. When present, it's an allowlist. `default` supplies
shared defaults. Each bucket entry can override region, endpoint, credentials,
request options, and cache policy.

## Decode planning

For transform chains proven safe for one-pass reads, ImagePlug may open the
source image with libvips sequential access before resizing. The first supported
shapes cover fit and force resize requests with concrete target dimensions. These
shapes may use sequential access whether the result downscales or upscales.

Chains involving crop, cover, or fill result crops, canvas extension, unknown
transforms, output-only requests, or no geometry transform continue to use
random access.

When a parsed plan contains more than one image pipeline, ImagePlug materializes the
image between pipelines. This preserves the explicit pipeline boundary and lets
source decode planning consider the first pipeline only. Later pipelines may
contain operations classified as requiring random access. Those operations use
a memory-backed intermediate image instead of changing how ImagePlug
opens the source image.

Sequential decode doesn't use JPEG shrink-on-load or WebP scale hints in this
pass. Source byte limits, receive timeouts, decoded pixel limits, and decode
error responses still apply. Cache hits serve stored response bodies directly
and skip source decode optimization.

## Automatic output

Automatic output format selection uses the request `Accept` header only to
detect optional modern format support. `q=0` excludes AVIF and WebP candidates,
including exact media-type exclusions over wildcard allowances.

Among detected modern candidates, ImagePlug uses server preference order rather
than relative q-value ordering. If ImagePlug detects no enabled modern
candidate, output-capable source families use the decoded source format.
Source-only input families fall back after transforms: PNG when the final image
has an alpha channel, JPEG otherwise. Automatic output responses use `Vary:
Accept`. Explicit formats bypass content negotiation and don't set `Vary:
Accept`.
