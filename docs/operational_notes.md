# Operational notes

ImagePipe verifies Imgproxy signatures and parses Imgproxy path options before
fetching source bytes. Invalid signatures return `403`, and invalid processing
requests return `400`, both without source traffic.

Parser and plan validation finish before source resolution, cache lookup, or
fetch. Source resolution finishes before cache lookup. Requests whose resolved
source has `internal_cache: :enabled` look up the cache before source fetch and
decode. Fetch and decode run only on a cache miss. They also run when a source
uses `internal_cache: :disabled`.

No-cache requests, `internal_cache: :disabled` requests, cache misses, cache
read errors, and invalid cache hits use a supervised source session for lazy
response streaming. The session owns the source-backed image and encoder
continuation. The Plug request process receives only prepared response metadata,
the first encoded chunk, and callbacks for pulling later chunks.

ImagePipe pulls the first encoded chunk before committing response headers. A
failure before that point can still become a normal ImagePipe error response.
After `send_chunked/2`, late source, decode, encode, cache staging, and client-close
failures have different response effects. Source, decode, encode, and
client-close failures stop delivery and skip partial cache writes. Cache staging
over-limit, staging errors, and cache commit errors fail open, emit telemetry,
and keep the response delivery result. In all cases, ImagePipe can't replace an
already-started response with a new HTTP error body.

Runtime cache read, metadata, and write errors fail open. Invalid cache
configuration still fails during Plug initialization.

HTTP and S3 source fetches use non-bang Req calls with bounded redirects and
receive timeouts. ImagePipe reads the source format from the decoded image
rather than trusted HTTP headers. `:max_body_bytes` defaults to `10_000_000`
bytes. `:max_input_pixels` defaults to `40_000_000` pixels after decode. Override
both in `ImagePipe.Plug` init options.

Static result limits run after transform execution and before final output
resolution or encoding. `:max_result_width` and `:max_result_height` default
to `8_192`. `:max_result_pixels` defaults to `40_000_000`. Result dimensions
mean the final static image width, height, and pixel count. Oversize static
results return `413` with `result image is too large`. Animation frame limits
remain out of scope and aren't implemented.

Built-in HTTP and S3 `req_options` are host-owned behavior. They must not vary
source bytes for the same resolved identity. Byte-selecting request options need
URI/object revision material, `internal_cache: :disabled`, or a custom adapter
identity field.

S3 `buckets` is a map. When present, it's an allowlist. `default` supplies
shared defaults. Each bucket entry can override region, endpoint, credentials,
request options, and cache policy.

## Decode planning

For transform chains proven safe for one-pass reads, ImagePipe may open the
source image with libvips sequential access before resizing. The first supported
shapes cover fit and force resize requests with concrete target dimensions. These
shapes may use sequential access whether the result downscales or upscales.

Chains involving crop, cover, or fill result crops, canvas extension, unknown
transforms, output-only requests, or no geometry transform continue to use
random access.

When a parsed plan contains more than one image pipeline, ImagePipe materializes the
image between pipelines. This preserves the explicit pipeline boundary and lets
source decode planning consider the first pipeline only. Later pipelines may
contain operations classified as requiring random access. Those operations use
a memory-backed intermediate image instead of changing how ImagePipe
opens the source image.

Sequential decode doesn't use JPEG shrink-on-load or WebP scale hints in this
pass. Source byte limits, receive timeouts, decoded pixel limits, and decode
error responses still apply. Cache hits serve stored response bodies directly
and skip source decode optimization.

## libvips format support

ImagePipe accepts source families only when the deployed libvips build can read
them. The test suite exercises SVG rejection and source-only TIFF fallback with
real libvips loaders. Development and CI builds should include SVG load support
and TIFF load/save support so missing loader support can't hide format support
drift.

## Automatic output

Automatic output format selection uses the request `Accept` header only to
detect optional modern format support. `q=0` excludes AVIF and WebP candidates,
including exact media-type exclusions over wildcard allowances.

Among detected modern candidates, ImagePipe uses server preference order rather
than relative q-value ordering. If ImagePipe detects no enabled modern
candidate, output-capable source families use the decoded source format. Source
families without encoder support fall back after transforms: PNG when the final
image has an alpha channel, JPEG otherwise. Automatic output responses use
`Vary: Accept`. Explicit formats bypass content negotiation and don't set
`Vary: Accept`.
