# ImagePlug

`ImagePlug` is an image optimization server, written as a `Plug`.

Uses the [image](https://hex.pm/packages/image) library under the hood.

Probably not quite ready for prime time yet.

Name not final!

## Native Path API

ImagePlug's native API uses path-oriented URLs:

```text
/<signature>[/<option>...]/plain/<origin_path>
```

For local development, the signature segment can be `_` or `unsafe`:

```text
/_/plain/images/cat-300.jpg
/_/w:300/plain/images/cat-300.jpg
/_/rs:fill:300:300/g:ce/plain/images/cat-300.jpg
/_/rs:fit:800:0/f:webp/plain/images/cat-300.jpg
/_/rt:force/w:300/h:200/plain/images/cat-300.jpg
/_/rs:fill:300:300/plain/images/cat-300.jpg@webp
```

Options are declarative. Their order in the URL does not define processing order:

```text
/_/rs:fill:300:300/plain/images/cat-300.jpg
/_/h:300/w:300/rt:fill/plain/images/cat-300.jpg
```

Both URLs describe the same requested output. ImagePlug owns the fixed processing pipeline so it can optimize origin loading, resize, crop, and output encoding over time.

### Options

```text
resize:%resizing_type:%width:%height:%enlarge:%extend
rs:%resizing_type:%width:%height:%enlarge:%extend
size:%width:%height:%enlarge:%extend
s:%width:%height:%enlarge:%extend
resizing_type:%resizing_type
rt:%resizing_type
width:%width
w:%width
height:%height
h:%height
gravity:%type:%x_offset:%y_offset
g:%type:%x_offset:%y_offset
format:%extension
f:%extension
ext:%extension
plain source @extension
```

Supported resizing types are `fit`, `fill`, `force`, `auto`, and `fill-down`. Width and height values are pixel dimensions; `0` means unconstrained when accepted by the selected option.

Supported gravity values are the imgproxy compass anchors, `ce`, `no`, `so`, `ea`, `we`, `noea`, `nowe`, `soea`, `sowe`, focal point `fp:%x:%y`, and smart gravity `sm`. Smart gravity parses but is not planned in this slice.

Supported explicit output extensions are `webp`, `avif`, `jpeg`, `jpg`, `png`, and `best`. `jpg` normalizes to JPEG. `best` parses but is not planned in this slice.

The first `plain` segment terminates option parsing. Later path segments are treated as the origin path, even if they look like options.

Omitting an explicit output format enables automatic output selection. ImagePlug defaults automatic AVIF and WebP selection to enabled. Explicit `format`, `f`, `ext`, and plain-source `@extension` bypass `Accept` negotiation.

## Usage example

```elixir
defmodule ImagePlug.SimpleServer do
  use Plug.Router

  plug Plug.Static,
    at: "/",
    from: {:the_app_name, "priv/static"},
    only: ~w(images)

  plug :match
  plug :dispatch

  match "/images/*path" do
    send_resp(conn, 404, "404 Not Found")
  end

  forward "/",
    to: ImagePlug,
    init_opts: [
      root_url: "http://localhost:4000",
      param_parser: ImagePlug.ParamParser.Native
    ]
end
```

## Filesystem Cache

ImagePlug can cache complete encoded responses after successful processing:

```elixir
forward "/",
  to: ImagePlug,
  init_opts: [
    root_url: "http://localhost:4000",
    param_parser: ImagePlug.ParamParser.Native,
    cache:
      {ImagePlug.Cache.FileSystem,
       root: "/var/cache/image_plug",
       path_prefix: "processed",
       # Encoded response cache storage limit, separate from the top-level origin fetch limit.
       max_body_bytes: 10_000_000,
       key_headers: [],
       key_cookies: [],
       fail_on_cache_error: false}
  ]
```

Cache lookup happens only after the request parses, the pipeline plans, and the origin URL is resolved. Invalid requests return `400` before origin or cache access. Parser, planner, origin fetch, decode, transform, negotiation, and encode errors are never cached.

Cache keys include the resolved origin URL, canonical processing request fields, configured `:key_headers` and `:key_cookies`, and the selected automatic output format when output is automatic. They exclude request signatures, raw request paths, query strings, raw `Accept` headers, and unconfigured headers or cookies. Key material includes a schema version and deterministic primitive serialization. Explicit formats bypass `Accept` negotiation and therefore do not vary by `Accept`.

Cached response headers are restricted to `vary` and `cache-control`. Header names are normalized to lowercase, and duplicate allowed headers are preserved.

`ImagePlug.Cache.FileSystem` requires an absolute `:root`. The optional `:path_prefix` must be relative and rejects backslashes, duplicate-slash empty segments, `.`, `..`, and `~`-prefixed path segments. Cache paths are derived from generated hashes, not from request, origin, header, or cookie data.

Filesystem metadata has an independent `metadata_version` and includes the cached body filename, byte size, and SHA-256 digest. Body files are content-addressed by digest, and the metadata file is the atomic commit record. Overwrites or failed metadata commits can leave unreferenced body files behind; those are safe misses, not corrupt entries. Missing files, invalid metadata, and default filesystem read problems are cache misses by default. With `fail_on_cache_error: true`, invalid metadata and filesystem read problems become cache read errors.

Adapter errors returned to the cache coordinator fail open by default and are logged. Set `fail_on_cache_error: true` to fail closed with a `500` cache error instead. Invalid cache configuration is rejected during Plug initialization. Encoded response bodies over the cache `:max_body_bytes` are returned to the client but skipped for cache storage. `:max_body_bytes` must be `nil` or a non-negative integer.

Treat the cache root as trusted local configuration. Generated paths are validated to stay under the configured root, but the filesystem adapter does not defend against a local actor replacing directories inside the root with symlinks.

## Operational Notes

`ImagePlug` parses native path options before fetching the origin image. Invalid processing requests return `400` without origin traffic.

Origin fetches use non-bang Req calls with bounded redirects, receive timeout, image content-type validation, and a maximum response body size. Configure these with `:origin_max_redirects`, `:origin_receive_timeout`, `:max_body_bytes`, and `:max_input_pixels`.

For transform chains that are proven to be safe for one-pass reads, ImagePlug may open the origin image with libvips sequential access before resizing. The first supported shapes are width-only scale, height-only scale, and regular non-letterboxed contain; these shapes may use sequential access whether the result downscales or upscales. Chains involving crop, focus, cover, letterboxing, unknown transforms, output-only requests, or no geometry transform continue to use random access.

Sequential decode does not use JPEG shrink-on-load or WebP scale hints in this pass. Origin byte limits, receive timeouts, decoded pixel limits, and decode error responses still apply. Cache hits serve stored response bodies directly and do not participate in origin decode optimization.

Automatic output format selection uses the request `Accept` header and sets `Vary: Accept` on image responses. Explicit formats bypass content negotiation.
