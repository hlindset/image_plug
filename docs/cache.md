# Cache

ImagePlug can cache complete encoded responses after successful processing:

```elixir
forward "/",
  to: ImagePlug,
  init_opts: [
    root_url: "http://localhost:4000",
    parser: ImagePlug.Parser.Imgproxy,
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

Cache lookup happens only after request parsing, plan validation, and origin
identity resolution. A lookup doesn't fetch, decode, or read metadata from the
origin image. Invalid parser and planner requests return `400` before origin or
cache access. Invalid imgproxy signatures return `403`. Parser, planner, origin
fetch, decode, transform, negotiation, and encode errors are never cached.

## Cache keys

Cache keys include:

- resolved origin identity and freshness data
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
cache paths, not request, origin, header, or cookie data.

Filesystem metadata has an independent `metadata_version` and includes the
cached body filename, byte size, and SHA-256 digest. Body files are
content-addressed by digest, and the metadata file is the atomic commit record.
Overwrites or failed metadata commits can leave unreferenced body files behind.
Those entries are safe misses, not corrupt entries.

Missing files, invalid metadata, and default filesystem read problems are cache
misses by default. With `fail_on_cache_error: true`, invalid metadata and
filesystem read problems become cache read errors.

Adapter errors returned to the cache coordinator fail open by default and log a
warning. Set `fail_on_cache_error: true` to fail closed with a `500` cache error
instead. Plug initialization rejects invalid cache configuration. The client
still receives encoded response bodies over the cache `:max_body_bytes` limit,
but the cache skips storage. `:max_body_bytes` must be `nil` or a non-negative
integer.

The filesystem adapter validates generated paths against the configured root
with `Path.safe_relative/2`, so paths that escape through symlinks fail as cache
path errors.
