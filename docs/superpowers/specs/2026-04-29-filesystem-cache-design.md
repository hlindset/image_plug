# Filesystem Cache Design

## Summary

Add optional internal caching for processed image responses. The first implementation stores complete encoded outputs on the local filesystem, keyed by the canonical `ImagePlug.ProcessingRequest` plus selected request headers or cookies.

This project is still a greenfield, unreleased library. Backwards compatibility is not a constraint for this design. Prefer clean cache boundaries and request pipeline structure over compatibility shims.

## Goals

- Serve repeated processed image requests from a persistent filesystem cache.
- Preserve the current parser and planner guarantees: invalid requests return before origin fetch and before cache access.
- Use `ImagePlug.ProcessingRequest` plus the resolved origin identity as the canonical cache-key input, not raw URL text.
- Exclude request signatures from the cache key so future signing key rotation does not invalidate cached images.
- Keep the first implementation simple with whole-body encoded-output reads and writes.
- Keep the cache integration structured so later filesystem streaming reads and write-through streaming can be added without replacing cache key generation.
- Prevent filesystem traversal by deriving all cache paths from ImagePlug-generated hashes, never from client-controlled path fragments.

## Non-Goals

- No S3, object-storage, or remote-cache adapter in the first implementation.
- No end-to-end origin streaming in this cache work.
- No cache invalidation API beyond cache-key changes and filesystem cleanup outside ImagePlug.
- No cache for raw passthrough or skip-processing modes.
- No backwards compatibility preservation for the older Twicpics query parser shape.

## Related GitHub Issues

- [#35 Investigate Image.from_req_stream for streaming origin decoding](https://github.com/hlindset/image_plug/issues/35): related but separate. Cache work must not require source streaming. The spec should leave room for later origin streaming or temp-file decode work.
- [#28 Optimize input decoding for large downscales](https://github.com/hlindset/image_plug/issues/28): related through memory and source decode efficiency. Filesystem cache reduces repeat processing cost but does not optimize first-request decode.
- [#33 Add raw and skip-processing response modes](https://github.com/hlindset/image_plug/issues/33): explicitly out of scope. Cache entries represent processed outputs from the normal pipeline.
- [#26 Add signed image URLs](https://github.com/hlindset/image_plug/issues/26): cache keys must exclude signatures, but signature validation must happen before cache lookup once signing exists.
- [#10 Add telemetry around origin fetch, decode, transform, and encode](https://github.com/hlindset/image_plug/issues/10): cache should expose clear points for future telemetry events, such as cache hit, miss, read error, write error, and skipped write.

## Current Pipeline

Current `ImagePlug.call/2` does this:

1. Parse the connection into `ImagePlug.ProcessingRequest`.
2. Plan the request into a transform chain through `ImagePlug.PipelinePlanner`.
3. Build and fetch the origin URL.
4. Decode the full origin response body with `Image.from_binary/2`.
5. Validate input pixels.
6. Execute transforms.
7. Negotiate or apply output format.
8. Stream encoded output chunks to the client.

The cache should integrate after step 2 and after origin URL construction, but before origin fetch. Planner failures should still return the parser's `400` response path and should not touch origin or cache storage. Origin URL construction failures should keep the current origin-error behavior and should not be hidden by cache hits.

## Proposed Pipeline

When `:cache` is not configured, preserve the current pipeline.

When `:cache` is configured:

1. Parse the connection into `ImagePlug.ProcessingRequest`.
2. Plan the request into a transform chain.
3. Build the origin identity for the request, currently the resolved origin URL from `root_url` and `ProcessingRequest.source_path`.
4. Build an `ImagePlug.Cache.Key` from the request, origin identity, and cache key options.
5. Attempt cache lookup.
6. On cache hit, send the cached response body and metadata.
7. On cache miss, run the normal origin, decode, validate, transform, and encode path.
8. Encode the final image into a complete binary.
9. If the encoded body is within cache limits, store it as an `ImagePlug.Cache.Entry`.
10. Send the encoded body to the client.

This first version intentionally changes the cache-enabled miss path from encoder streaming to whole-body response sending. The normal uncached path can continue streaming as it does today.

## Public Configuration

Initial usage:

```elixir
forward "/",
  to: ImagePlug,
  init_opts: [
    root_url: "http://localhost:4000",
    param_parser: ImagePlug.ParamParser.Native,
    cache: {ImagePlug.Cache.FileSystem,
      root: "/var/cache/image_plug",
      path_prefix: "processed",
      max_body_bytes: 10_000_000,
      key_headers: [],
      key_cookies: [],
      report_errors: false
    }
  ]
```

Options:

- `:root` is required for filesystem cache.
- `:path_prefix` is optional and scopes cache files under the root.
- `:max_body_bytes` skips cache writes larger than the limit.
- `:key_headers` is a list of request headers included in the cache key.
- `:key_cookies` is a list of request cookies included in the cache key.
- `:report_errors` defaults to `false`. When false, cache errors are logged and processing continues without cache. When true, cache errors fail the request.

## Cache Key

Cache key material:

- cache key schema version
- resolved origin identity, currently the origin URL built from `root_url` and `ProcessingRequest.source_path`
- `ProcessingRequest.source_kind`
- `ProcessingRequest.source_path`
- `ProcessingRequest.width`
- `ProcessingRequest.height`
- `ProcessingRequest.fit`
- `ProcessingRequest.focus`
- `ProcessingRequest.format`
- selected request headers from `:key_headers`
- selected request cookies from `:key_cookies`

Excluded:

- `ProcessingRequest.signature`
- raw request path
- query string
- headers and cookies not configured as key material

The resolved origin identity prevents collisions when multiple ImagePlug instances use different `root_url` values but share the same cache root. Future source kinds can define their own stable origin identity.

The key should be generated from stable Erlang terms or a deterministic JSON-like structure, then hashed. Use hash-partitioned filesystem paths to avoid large flat directories.

Example path shape:

```text
<root>/<path_prefix>/ab/cd/abcdef...body
<root>/<path_prefix>/ab/cd/abcdef...meta
```

### `format:auto`

For explicit formats, the requested format is sufficient key material.

For `format:auto`, include a normalized `Accept` value in the cache key. The first implementation should do syntactic normalization: downcase media ranges and parameter names, trim optional whitespace, sort duplicate-equivalent entries in a deterministic way, and preserve q-values. The cache entry stores the selected response content type.

Do not key `format:auto` entries only by the final negotiated output format in the first implementation. Current negotiation intentionally depends on `Image.has_alpha?/1` to preserve transparency: alpha-capable outputs can be selected for transparent sources, and PNG remains the safe legacy fallback when AVIF or WebP are unavailable. `Image.has_alpha?/1` is known only after origin fetch and decode. Moving lookup after decode would make cache hits unable to avoid origin traffic. Checking multiple possible negotiated-format keys before decode could serve the wrong cached variant when the same source path has cached alpha and non-alpha outcomes under different origin content. Keying by normalized `Accept` is less compact but preserves pre-origin cache hits and correctness.

Future work can improve semantic `Accept` equivalence if cache fragmentation becomes a real problem.

If ImagePlug later adds explicit background or flattening controls, output negotiation can be revisited. At that point, transparent sources could safely negotiate to non-alpha formats such as JPEG by flattening against a configured background. Until then, alpha-aware negotiation should remain the safer default.

## Cache Entry

`ImagePlug.Cache.Entry` should represent response data independent of the storage adapter:

```elixir
%ImagePlug.Cache.Entry{
  body: encoded_binary,
  content_type: "image/webp",
  headers: [{"vary", "Accept"}],
  created_at: DateTime.utc_now()
}
```

The first version stores `body` directly. Do not spread filesystem concerns into `ImagePlug.call/2`; keep body sending and cache storage behind small functions so later streaming read/write can replace the internals.

## Cache Behaviour

First implementation API:

```elixir
@callback get(ImagePlug.Cache.Key.t(), keyword()) ::
            {:hit, ImagePlug.Cache.Entry.t()} | :miss | {:error, term()}

@callback put(ImagePlug.Cache.Key.t(), ImagePlug.Cache.Entry.t(), keyword()) ::
            :ok | {:error, term()}
```

The adapter receives adapter-specific options from the `:cache` tuple. The top-level cache coordinator handles `report_errors` policy consistently.

## Filesystem Adapter

`ImagePlug.Cache.FileSystem` responsibilities:

- Validate required `:root`.
- Build cache paths from key hash and optional path prefix.
- Read metadata and body files on lookup.
- Treat missing or invalid metadata/body as `:miss`.
- Write body and metadata to unique temp files.
- Atomically rename temp files into final paths only after successful writes.
- Clean up temp files on write failure when possible.

Metadata should include at least:

- schema version
- content type
- response headers
- created timestamp
- body byte size

Do not count a hit unless both body and metadata are present and valid.

## Security

Filesystem cache paths must never contain raw request path segments, origin URL text, header values, cookie values, or other client-controlled strings. The only client-influenced filesystem path component should be the encoded cache-key hash generated by ImagePlug.

Path construction requirements:

- Resolve and expand `:root` at adapter initialization or before use.
- Reject missing or non-absolute `:root` values.
- Treat `:path_prefix` as configuration, not request data.
- Normalize and validate `:path_prefix` so it cannot be absolute, cannot contain backslashes, and cannot contain `.` or `..` path segments.
- Build final body, metadata, and temp paths from `root`, validated `path_prefix`, hash partition directories, and fixed suffixes.
- Verify final paths remain under the resolved cache root before reading, writing, renaming, or deleting.
- Use exclusive temp filenames generated by the adapter, not request-derived filenames.

Arbitrary file reads should not be possible if these constraints hold, because lookup paths are derived from a fixed root and ImagePlug-generated hash. The implementation should still test traversal-shaped configuration and malformed metadata cases because filesystem cache bugs are high-impact.

## Error Handling

Default behavior is fail-open for cache errors:

- Cache read error: log and process as miss.
- Cache write error: log and still return the processed response.
- Body over `max_body_bytes`: skip write and return the processed response.

With `report_errors: true`:

- Cache read errors fail before origin fetch.
- Cache write errors fail if the response has not been sent.

Because the first cache-enabled miss path buffers the encoded body before sending, write failures can still be reported cleanly when `report_errors: true`.

## Streaming Posture

The first cache implementation is not end-to-end streaming:

- Origin fetch remains full-body.
- Cache reads return full body.
- Cache writes store full encoded body.
- Cache-enabled misses send a full encoded body.

However, the design must keep future streaming possible:

- Cache keys and entries are separate from filesystem paths.
- Response sending is isolated from cache lookup and storage.
- Encoding for cacheable misses is isolated enough to later replace whole-body encode with write-through streaming.

Future streaming API shape:

```elixir
open_read(key, opts)
read_chunk(reader)
close_read(reader)

open_write(key, metadata, opts)
write_chunk(writer, chunk)
commit(writer)
abort(writer)
```

Likely future increments:

1. Stream cache hits from filesystem to the client.
2. Tee encoder chunks to a temp cache file during cache misses.
3. Investigate origin streaming separately through issue #35.

## Testing Strategy

Unit tests:

- Cache key excludes signature.
- Cache key is stable across native option order when parsed to equivalent `ProcessingRequest` values.
- Cache key includes configured headers and cookies.
- `format:auto` includes normalized `Accept` input.
- Filesystem adapter returns `:miss` for missing body or metadata.
- Filesystem adapter stores and retrieves valid entries.
- Filesystem adapter uses atomic temp writes.
- Filesystem adapter rejects unsafe `:root` and `:path_prefix` configuration.
- Filesystem adapter never resolves body, metadata, or temp paths outside the cache root.

Property tests:

- Cache key generation is deterministic for equivalent `ProcessingRequest` values.
- Cache key generation excludes signatures across arbitrary signature strings.
- Cache key hashes and filesystem paths never contain raw source path, header, cookie, or signature input.
- Filesystem path generation keeps all generated body, metadata, and temp paths under the cache root for arbitrary cache keys and valid prefixes.
- Basic `Accept` normalization is idempotent.

Integration tests:

- Cache miss fetches origin, processes image, stores entry, and returns response.
- Cache hit does not fetch origin.
- Invalid parser request does not touch cache.
- Invalid planner request does not touch cache.
- Explicit output format responses cache with the expected content type.
- Auto output responses cache with `Vary: Accept` and the negotiated content type.
- Oversized encoded responses skip cache writes.
- Cache read/write errors fail open by default.
- `report_errors: true` makes cache errors visible.

Regression tests:

- Existing uncached request behavior remains covered.
- Cache disabled path keeps current streaming encoder behavior.

## Documentation

Update README or module docs with:

- Filesystem cache configuration.
- Cache key behavior.
- Signature exclusion rationale.
- `format:auto` and `Accept` behavior.
- Error handling policy.
- Explicit note that first implementation is whole-body and not end-to-end streaming.

## Open Decisions Resolved

- First adapter: filesystem only.
- First storage mode: complete encoded body.
- First delivery mode: ImagePlug sends cached responses.
- End-to-end streaming: deferred and not a prerequisite.
- Backwards compatibility: not a constraint because the library is greenfield and unreleased.
