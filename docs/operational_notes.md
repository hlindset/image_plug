# Operational notes

ImagePlug verifies imgproxy signatures and parses imgproxy path options before
fetching the origin image. Invalid signatures return `403`, and invalid
processing requests return `400`, both without origin traffic.

Origin fetches use non-bang Req calls with bounded redirects, receive timeout,
and a max response body size. ImagePlug reads the source format from the decoded
image rather than trusted HTTP headers. Configure these limits with
`:origin_max_redirects`, `:origin_receive_timeout`, `:max_body_bytes`, and
`:max_input_pixels`.

## Decode planning

For transform chains proven safe for one-pass reads, ImagePlug may open the
origin image with libvips sequential access before resizing. The first supported
shapes cover fit and force resize requests with concrete target dimensions. These
shapes may use sequential access whether the result downscales or upscales.

Chains involving crop, cover, or fill result crops, canvas extension, unknown
transforms, output-only requests, or no geometry transform continue to use
random access.

When a parsed plan contains multiple image pipelines, ImagePlug materializes the
image between pipelines. This preserves the explicit pipeline boundary and lets
origin decode planning consider the first pipeline only. Later pipelines may
contain operations classified as requiring random access. Those operations run
against a memory-backed intermediate image instead of changing how ImagePlug
opens the origin image.

Sequential decode doesn't use JPEG shrink-on-load or WebP scale hints in this
pass. Origin byte limits, receive timeouts, decoded pixel limits, and decode
error responses still apply. Cache hits serve stored response bodies directly
and skip origin decode optimization.

## Automatic output

Automatic output format selection uses the request `Accept` header only to
detect optional modern format support. `q=0` excludes AVIF and WebP candidates,
including exact media-type exclusions over wildcard allowances.

Among detected modern candidates, ImagePlug uses server preference order rather
than relative q-value ordering. If ImagePlug detects no enabled modern
candidate, it uses the source image format. Automatic output responses use
`Vary: Accept`. Explicit formats bypass content negotiation and don't set
`Vary: Accept`.
