# Cache

ImagePipe can cache complete encoded responses after successful processing:

```elixir
forward "/",
  to: ImagePipe,
  init_opts: [
    parser: ImagePipe.Parser.Imgproxy,
    sources: [
      path: {ImagePipe.Source.File, root: "/srv/images", root_id: "primary"}
    ],
    cache:
      {ImagePipe.Cache.FileSystem,
       root: "/var/cache/image_pipe",
       path_prefix: "processed",
       max_body_bytes: 10_000_000,
       key_headers: [],
       key_cookies: []}
  ]
```

Cache lookup happens only after request parsing, plan validation, and source
resolution. A lookup doesn't fetch, decode, or read metadata from the source
image. Invalid parser and planner requests return before source fetch or cache
access. Invalid Imgproxy signatures return `403`. Parser, planner, source
fetch, decode, transform, negotiation, and encode errors are never cached.

## Cache misses and streaming

On cache read, ImagePipe validates the returned entry before treating it as a
hit. The entry must have a binary body, cacheable headers, and one of the
supported output content types: JPEG, PNG, WebP, or AVIF. If that check passes,
ImagePipe sends the stored body without fetching, decoding, transforming, or
encoding the source image.

If cache entry validation fails, ImagePipe treats the hit like a miss. It
reprocesses through a supervised source session using the same cache key and
emits cache read telemetry for the invalid entry.

Configured cache misses and cache read errors stream through a supervised source
session. The session owns source fetch, decode, transform execution, output
encoding, and cache staging. It returns the first encoded chunk before ImagePipe
commits response headers, then `ImagePipe.Response.Sender` pulls later chunks on
demand.

For those streamed cache misses, the source session writes encoded chunks into a
cache sink as it returns them to the sender. ImagePipe makes the staged cache
entry visible only after:

- the encoder stream finishes,
- the sender has successfully delivered every chunk returned by the session,
- and the staged body stayed within `:max_body_bytes`.

Client disconnects, owner process exits, explicit cancellation, source or encode
failures after the first chunk, and incomplete streams abort the staged entry and
don't write cache. If the staged body crosses `:max_body_bytes`, ImagePipe drops
cache staging, continues delivering the response, and skips the cache write.

Cache commit errors after successful streamed delivery fail open. The client
keeps the response body that was already delivered. ImagePipe emits cache write
telemetry and doesn't replace that response with a cache error. Cache staging
open or write errors also fail open and skip the cache write.

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

`ImagePipe.Cache.FileSystem` requires an absolute `:root`. The optional
`:path_prefix` must be relative and rejects backslashes, duplicate-slash empty
segments, `.`, `..`, and `~`-prefixed path segments. Generated hashes determine
cache paths, not request, source, header, or cookie data.

Filesystem metadata has an independent `metadata_version` and includes the
cached body filename, byte size, and SHA-256 digest. Body files are
content-addressed by digest.

Missing files are cache misses. Invalid metadata and filesystem read problems
are cache read errors from the adapter. The cache coordinator logs them, emits
cache read telemetry, and treats the lookup as a miss.

Adapter errors returned to the cache coordinator fail open and log a warning.
Plug initialization rejects invalid cache configuration. The client still
receives encoded response bodies over the cache `:max_body_bytes` limit, but the
cache skips storage. `:max_body_bytes` must be `nil` or a non-negative integer.

The filesystem adapter validates generated paths under the configured root
with `Path.safe_relative/2`, so paths that escape through symlinks fail as cache
path errors.
