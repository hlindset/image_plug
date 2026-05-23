# Transactional Cache Sink

## Decision

Replace `ImagePlug.Request.SourceSession.CacheBuffer` with a transactional cache
sink owned by `ImagePlug.Request.SourceSession`.

The sink should stage cache bytes as the response streams. It should make a
cache entry visible only after the encoder finishes and `Plug.Conn.chunk/2` has
accepted every chunk returned by the session. On cancellation, owner death,
client close, source failure, decode failure, encode failure, or cache size
overflow, the sink should abort without changing the HTTP response outcome.

Runtime cache failures fail open. Invalid cache configuration still fails during
`ImagePlug.init/1`, but lookup, read, write, commit, invalid-entry, and cleanup
problems should log and emit telemetry rather than fail an otherwise processable
image request.

## Current State

After `b15642d Remove fail-closed cache runtime option`, cache is a runtime
optimization:

- cache configuration validation finishes before request side effects
- lookup and read errors become misses
- invalid cache entries become misses
- write errors fail open
- configured cache misses stream through supervised `SourceSession`

After `a03a3ca Remove stale direct image response path`, processed responses no
longer have a sender-side `{:image, state, resolved_output, response}` delivery
path. Runtime delivery is now either a cache hit body or a prepared stream. That
means cache sink work only needs to replace `SourceSession.CacheBuffer`. It
doesn't need to support an old response-sender encoder path.

Slice 5 added `SourceSession.CacheBuffer` as a bridge over the existing cache
adapter contract:

```elixir
Cache.put(key, %Entry{body: binary}, opts)
```

That buffer stores encoded chunks in memory, turns them into one binary at
stream completion, and calls `Cache.put/3`. It preserves the existing adapter
API, but it means a cacheable response can occupy memory equal to the full
encoded body until the stream finishes.

That's acceptable only as a temporary bridge. It's the wrong shape for large
responses and for future S3 cache writes.

## Goals

- Keep `Response.Sender` cache-unaware.
- Keep `SourceSession` as the owner of lazy Vix encoding and cache staging.
- Keep prepared streams as the only processed-response delivery path.
- Avoid holding the full encoded response body in ImagePlug memory.
- Keep cache writes invisible to readers until commit.
- Abort staged cache data on every incomplete response path.
- Preserve fail-open runtime cache behavior.
- Make filesystem cache writes stream to temporary files.
- Leave room for an S3 multipart sink without changing `SourceSession` again.

## Non-Goals

- Don't add S3 caching in this slice.
- Don't add cache writer processes by default.
- Don't let cache staging consume the encoder stream independently of HTTP
  delivery.
- Don't make `Response.Sender` know about cache keys, sinks, entries, or cache
  errors.
- Don't reintroduce fail-closed runtime cache behavior.
- Don't restore the removed sender-side image encoding path.

## Cache Sink Contract

The cache boundary should expose a staged writer API:

```elixir
sink = Cache.open_sink(key, resolved_output, opts)

sink = Cache.write_chunk(sink, chunk, opts)

:ok = Cache.commit_sink(sink, opts)
:ok = Cache.abort_sink(sink, reason, opts)
```

`sink` should be opaque outside the cache boundary. `SourceSession` stores it
and passes it back to `ImagePlug.Cache`, but it must not inspect adapter, key,
status, or adapter state fields.

The internal sink state can still be a small struct:

```elixir
%ImagePlug.Cache.Sink{
  adapter: ImagePlug.Cache.FileSystem,
  key: %ImagePlug.Cache.Key{},
  state: adapter_state,
  status: :open | :dropped | :committed | :aborted
}
```

Keep `ImagePlug.Cache.Sink` inside the cache boundary. Export the cache API and
an opaque `Cache.sink()` type.

It shouldn't be a GenServer. `SourceSession` already serializes encoder
progress, sender demand, cancellation, owner monitoring, and stream completion.
Adding a process per cache write would duplicate lifecycle ownership and add
mailbox cleanup work without solving a current bottleneck.

Adapters can hide internal concurrency behind their sink state later. For
example, a future S3 adapter may start tasks for part uploads while keeping the
public sink API synchronous from `SourceSession`'s point of view.

The API consumed by `SourceSession` should fail open. Runtime open or write
failures should return `nil` after telemetry and cleanup, or return a sink in a
terminal dropped state if that's easier internally. They shouldn't return a
tagged error that `SourceSession.prepare/1` or `SourceSession.next/1` can
mistake for an image-processing failure. Invalid configuration remains an
initialization error before request handling starts.

## Adapter Callbacks

Extend the cache behaviour with callbacks shaped like:

```elixir
@callback open_sink(Key.t(), Entry.Metadata.t(), keyword()) ::
            {:ok, state()} | {:error, term()}

@callback write_chunk(state(), binary(), keyword()) ::
            {:ok, state()} | {:error, term(), state()}

@callback commit_sink(state(), keyword()) ::
            :ok | {:error, term()}

@callback abort_sink(state(), keyword()) ::
            :ok | {:error, term()}
```

The cache coordinator should own shared behavior:

- option validation
- `:max_body_bytes` tracking
- fail-open logging and telemetry
- turning unsupported adapter results into cache errors
- representing "no cache" as `nil`, not a no-op adapter
- building cache entry metadata from `ImagePlug.Output.Resolved`
- normalizing cacheable headers
- setting `created_at`

Adapters should own storage-specific staging:

- filesystem paths and file handles
- S3 multipart upload IDs and uploaded part lists
- memory-backed sink state for test or in-memory adapters

The metadata passed to adapters should be cache-owned and body-free:

```elixir
%ImagePlug.Cache.Entry.Metadata{
  content_type: String.t(),
  headers: [ImagePlug.Cache.Entry.header()],
  created_at: DateTime.t(),
  output_format: atom()
}
```

`SourceSession` should pass the resolved output to the cache API. It shouldn't
build adapter metadata or call `ImagePlug.Cache.Entry.cacheable_headers/1`
itself.

## SourceSession Flow

`SourceSession` should replace `cache_buffer` with:

```elixir
cache_sink: nil | ImagePlug.Cache.sink()
```

`nil` means this response doesn't cache. Use no no-op sink.

Prepare flow:

1. Fetch, decode, transform, and resolve output as `SourceSession` does today.
2. Open a cache sink if the request has a cache key and output metadata.
3. Create the encoder stream.
4. Pull the first encoded chunk.
5. Write the first chunk to the sink.
6. Return prepared response metadata and the first chunk.

If source or decode fails before output resolution, no sink should exist.
If opening or writing the first chunk to the sink fails, `SourceSession` should
turn caching off for that response. `prepare/1` should still return the prepared
stream unless the image work itself failed.

Next flow:

1. Resume the suspended encoder continuation once.
2. If it returns a chunk, write that chunk to the sink.
3. Return the chunk to `Response.Sender`.
4. If it reaches normal completion, commit the sink and return `:done`.

Failure flow:

- explicit cancel halts the encoder continuation, then aborts the sink
- owner death halts the encoder continuation, then aborts the sink
- client close causes `Response.Sender` to call cancel, which aborts the sink
- source, decode, output, or encode failure aborts the sink
- cache sink write failure attempts adapter abort once and continues delivery
- cache sink commit failure performs commit-owned cleanup, emits cache write
  telemetry, and still returns `:done`

This preserves the existing delivery rule: cache state must not decide whether an
already-successful image delivery becomes an HTTP failure.

Sink cleanup should be idempotent at the cache API. Repeated aborts are
harmless. Abort after commit must not remove a visible cache entry. Write or
commit after a dropped or aborted sink should fail open and shouldn't call the
adapter again.

## Delivery Ordering

`SourceSession` should write each chunk to the sink before returning it to the
sender. That keeps cache staging from lagging behind bytes that ImagePlug has
already handed to the response layer.

The sender calls `next/0` only after `Plug.Conn.chunk/2` returns `{:ok, conn}`
for the previous chunk. When `SourceSession.next/1` observes stream completion,
the response adapter has accepted every returned chunk. That's the commit point.
This doesn't prove that a remote client has received every byte.

If writing a chunk to the sink fails, cache staging should stop for that
response. Return the chunk to the sender unless the image stream itself failed.

Before committing, `SourceSession` should keep the current control-message check
for owner death. The prepared-stream callback driver should remain the request
owner. Moving callbacks into another process would need a new commit-safety
review.

## Filesystem Sink

The filesystem adapter should stream the body to temporary files under the same
validated cache root and partition path as the final entry.

Suggested state:

```elixir
%{
  paths: paths,
  temp_body_path: binary(),
  temp_meta_path: binary(),
  body_io: io_device(),
  size: non_neg_integer(),
  body_hash_context: term(),
  metadata: ImagePlug.Cache.Entry.Metadata.t(),
  content_type: String.t(),
  headers: [ImagePlug.Cache.Entry.header()]
}
```

Open:

- check final cache paths
- create the cache directory
- create a unique temporary body path in that directory
- open the body file for binary write

Write:

- write the chunk to the temporary body file
- update byte count and SHA-256 state

Commit:

- close the body file
- write metadata to a temporary metadata path
- rename the temporary body file to the final body filename
- rename the temporary metadata file to the final metadata path
- if any commit step fails, close the body file and remove remaining temporary
  files; if the body was already renamed, remove or overwrite it before
  returning the commit error

Abort:

- close the body file if open
- remove temporary body and metadata files

Readers should continue to use committed metadata paths only. They should never
look for temporary files, so staged writes remain invisible.

Filesystem writes run inside `SourceSession` callbacks, so they must remain
bounded local file operations. The sink shouldn't add fsync-heavy durability
work to the response path unless that behavior is explicitly designed.

## Future S3 Sink

An S3 sink can use the same cache sink contract with multipart upload:

- `open_sink/3` starts a multipart upload
- `write_chunk/3` appends to a pending part buffer
- when the buffer reaches S3's required part size, the sink uploads a part
- `commit_sink/2` uploads the final smaller part and completes the multipart
  upload
- `abort_sink/2` aborts the multipart upload

The S3 sink still buffers bytes, but only for the current part. It shouldn't
hold the whole image body in memory.

An S3 implementation still needs its own adapter-level design. It must split
large encoder chunks across parts, cap the pending part buffer, and respect S3
part size and part count rules. It must also track part numbers and entity tags,
wait for in-flight part uploads before completing the multipart upload, and
abort in-flight uploads on cancellation. Network-backed sinks must not perform
unbounded network IO in the `SourceSession` GenServer callback.

Adapters can add asynchronous part uploads inside the S3 adapter later, but
`commit_sink/2` must be the synchronization and failure point and
`abort_sink/2` must stop or await adapter-owned upload work.

## Size Limit Behavior

`:max_body_bytes` remains a cache storage limit, not a response delivery limit.

The cache coordinator should track written byte count. If a write would cross
the limit:

- stop cache staging for this response
- attempt adapter abort once
- mark the sink dropped after cleanup
- emit `cache: :write_skipped` with `reason: :too_large`
- continue HTTP response delivery

The sink shouldn't rely on every adapter duplicating this limit correctly.

## Telemetry

Keep the existing cache event shape where possible:

```text
[:image_plug, :cache, :write, :start]
[:image_plug, :cache, :write, :stop]
```

Use `[:cache, :write]` for sink commit attempts. Commit metadata should report
whether the entry became visible or whether commit failed open.

Use `[:cache, :tee]` for staging outcomes that don't call the adapter commit:

- `cache: :write_skipped`, `reason: :too_large`
- `cache: :abandoned`, `reason: :cancelled`
- `cache: :abandoned`, `reason: :owner_down`
- `cache: :abandoned`, `reason: :stream_error`
- `cache: :write_error` when staging failed before commit and delivery
  continued
- `cache: :cleanup_error` when abort cleanup fails after the response path has
  already failed open

Don't emit cache keys, source URLs, request paths, filenames, adapter module
names, transform internals, or raw exception structs.

## Error Semantics

Invalid cache configuration remains a startup/init error.

Runtime cache sink errors fail open:

- open failure disables caching for the response
- write failure disables caching for the response
- commit failure records telemetry and leaves response delivery successful
- abort failure records telemetry or logs only

If a cache sink fails before headers commit, ImagePlug could still choose to
return an error, but it shouldn't. Cache is an optimization after the
fail-closed option removal.

## Why Not A GenServer Sink

A per-response cache writer process isn't the default design.

It would add:

- another lifecycle owner
- another cancellation path
- extra mailbox pressure rules
- more cleanup cases during owner death and application shutdown

Those costs aren't needed for filesystem staging. For S3, adapter-internal
tasks may be useful for part uploads, but that can stay behind the adapter state
instead of changing the top-level cache contract.

## Why Not Let The Adapter Consume The Stream

Giving the cache adapter the encoder stream would let it read ahead of the HTTP
client. That breaks the pull model that prepared streams established.

`Response.Sender` owns socket pressure. It calls `next/0` after each
successful chunk write. The cache sink must follow that rhythm instead of
driving the encoder independently.

## Migration

The implementation should be one slice:

1. Add cache sink tests and callback contract.
2. Add the cache coordinator sink API.
3. Add filesystem sink staging.
4. Replace `SourceSession.CacheBuffer` with `cache_sink`.
5. Delete `SourceSession.CacheBuffer`.
6. Update telemetry and docs.

The prepared-stream cache miss path shouldn't call `Cache.put/3` directly after
this slice. If tests or helper code still need `Cache.put/3`, rewrite it through
the sink as a whole-body helper. Adapter modules should have one write contract:
the sink callbacks.

Stop criteria for this slice:

- `SourceSession.CacheBuffer` has no references.
- `Response.Sender` remains cache-unaware.
- `Response.Sender` still has no sender-side image encoding path.
- Prepared-stream cache misses don't accumulate the full encoded body in
  ImagePlug memory.
- Filesystem cleanup removes temp body and metadata files on cancel, owner death,
  stream error, write error, size overflow, and commit failure.
- Oversize cache bodies continue HTTP delivery and don't create visible cache
  entries.
- Runtime sink open, write, commit, and abort errors fail open and emit the
  documented telemetry.
- Boundary exports expose the cache API, not adapter sink internals.

## Open Questions For Implementation

- Whether filesystem commit should rename body first or metadata first. Readers
  currently discover entries through metadata, so metadata should become visible
  last.
- Whether temporary files should live in the final partition directory or a
  dedicated temp directory under the cache root. The final partition directory
  keeps rename atomic on a single filesystem.
- Whether abort failures need telemetry and logs. They shouldn't
  affect HTTP delivery.
- Whether to keep `Cache.put/3` as a helper after rewriting it through the sink,
  or remove it if no non-test caller needs whole-body cache writes.
