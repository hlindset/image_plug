# Cache

ImagePlug can cache complete encoded responses after successful processing:

```elixir
forward "/",
  to: ImagePlug,
  init_opts: [
    parser: ImagePlug.Parser.Imgproxy,
    sources: [
      path: {ImagePlug.Source.File, root: "/srv/images", root_id: "primary"}
    ],
    cache:
      {ImagePlug.Cache.FileSystem,
       root: "/var/cache/image_plug",
       path_prefix: "processed",
       max_body_bytes: 10_000_000,
       key_headers: [],
       key_cookies: [],
       fail_on_cache_error: false}
  ]
```

Cache lookup happens only after request parsing, plan validation, and source
resolution. A lookup doesn't fetch, decode, or read metadata from the source
image. Invalid parser and planner requests return before source fetch or cache
access. Invalid Imgproxy signatures return `403`. Parser, planner, source
fetch, decode, transform, negotiation, and encode errors are never cached.

## Cache misses and streaming

Cache hits return the stored body directly when the cached entry has deliverable
response metadata. That path doesn't fetch, decode, transform, or encode the
source image.

If a cache hit has response metadata ImagePlug can't deliver, the default
fail-open behavior treats it like a miss. ImagePlug reprocesses through a
supervised source session using the same cache key. With
`fail_on_cache_error: true`, the same invalid hit becomes a cache error.

With the default `fail_on_cache_error: false`, configured cache misses and
fail-open cache read errors stream through a supervised source session. The
session owns source fetch, decode, transform execution, output encoding, and the
cache tee. It returns the first encoded chunk before ImagePlug commits response
headers, then `ImagePlug.Response.Sender` pulls later chunks on demand.

For those streamed cache misses, the cache tee buffers encoded chunks inside the
source session. ImagePlug writes the cache entry only after:

- the encoder stream finishes,
- the sender has successfully delivered every chunk returned by the session,
- and the buffered body stayed within `:max_body_bytes`.

Client disconnects, owner process exits, explicit cancellation, source or encode
failures after the first chunk, and incomplete streams abandon the buffer and do
not write cache. If the buffered body crosses `:max_body_bytes`, ImagePlug drops
the buffer, continues delivering the response, and skips the cache write.

Cache write errors after successful streamed delivery fail open. The client
keeps the response body that was already delivered. ImagePlug emits cache write
telemetry and doesn't replace that response with a cache error.

With `fail_on_cache_error: true`, cacheable misses stay on the pre-response
cache path. ImagePlug finishes encoding before delivery, and writes a cache
entry when the encoded body stays within `:max_body_bytes`. If the body is too
large, ImagePlug skips the cache write and sends the encoded response. Cache
read and write errors on that path can become `500` cache errors.

## Cache keys

Cache keys include:

- resolved source identity
- canonical Plan operation key data
- the cache key's transform key data version
- configured `:key_headers` and `:key_cookies`
- normalized automatic-output inputs when output is automatic: detected modern
  output candidates plus `:auto_avif` and `:auto_webp` flags

Cache keys exclude:

- request signatures
- raw request paths
- query strings
- raw `Accept` headers
- source metadata
- decoded image properties
- source-aware execution choices
- unconfigured headers and cookies

Key data includes a schema version and deterministic primitive serialization.
Explicit formats bypass `Accept` negotiation, so they don't vary by `Accept`.

## Stored headers

The cache stores only `vary` and `cache-control` response headers. It normalizes
header names to lowercase and preserves duplicate allowed headers.

## Filesystem adapter

`ImagePlug.Cache.FileSystem` requires an absolute `:root`. The optional
`:path_prefix` must be relative and rejects backslashes, duplicate-slash empty
segments, `.`, `..`, and `~`-prefixed path segments. Generated hashes determine
cache paths, not request, source, header, or cookie data.

Filesystem metadata has an independent `metadata_version` and includes the
cached body filename, byte size, and SHA-256 digest. Body files are
content-addressed by digest.

Missing files, invalid metadata, and default filesystem read problems are cache
misses by default. With `fail_on_cache_error: true`, invalid metadata and
filesystem read problems become cache read errors.

Adapter errors returned to the cache coordinator fail open by default and log a
warning. Set `fail_on_cache_error: true` to fail closed with a `500` cache error
instead. Plug initialization rejects invalid cache configuration. The client
still receives encoded response bodies over the cache `:max_body_bytes` limit,
but the cache skips storage. `:max_body_bytes` must be `nil` or a non-negative
integer.

The filesystem adapter validates generated paths under the configured root
with `Path.safe_relative/2`, so paths that escape through symlinks fail as cache
path errors.
