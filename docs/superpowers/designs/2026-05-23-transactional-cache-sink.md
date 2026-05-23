# Transactional Cache Sink

## Decision

Replace `ImagePlug.Request.SourceSession.CacheBuffer` with a transactional cache
sink owned by `ImagePlug.Request.SourceSession`.

The sink should stage cache bytes as the response streams. It should make a
cache entry visible only after the encoder finishes and the sender has delivered
every chunk returned by the session. On cancellation, owner death, client close,
source failure, decode failure, encode failure, or cache size overflow, the sink
should abort or stop caching without changing the HTTP response outcome.

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

## Cache Sink Contract

The cache boundary should expose a staged writer API:

```elixir
{:ok, sink} = Cache.open_sink(key, metadata, opts)

{:ok, sink} = Cache.write_chunk(sink, chunk)

:ok = Cache.commit_sink(sink)
:ok = Cache.abort_sink(sink)
```

`Cache.Sink` should be a small struct:

```elixir
%ImagePlug.Cache.Sink{
  adapter: ImagePlug.Cache.FileSystem,
  key: %ImagePlug.Cache.Key{},
  state: adapter_state,
  status: :open | :dropped | :committed | :aborted
}
```

It shouldn't be a GenServer. `SourceSession` already serializes encoder
progress, sender demand, cancellation, owner monitoring, and stream completion.
Adding a process per cache write would duplicate lifecycle ownership and add
mailbox cleanup work without solving a current bottleneck.

Adapters can hide internal concurrency behind their sink state later. For
example, a future S3 adapter may start tasks for part uploads while keeping the
public sink API synchronous from `SourceSession`'s point of view.

## Adapter Callbacks

Extend the cache behaviour with callbacks shaped like:

```elixir
@callback open_sink(Key.t(), metadata(), keyword()) ::
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

Adapters should own storage-specific staging:

- filesystem paths and file handles
- S3 multipart upload IDs and uploaded part lists
- memory-backed sink state for test or in-memory adapters

## SourceSession Flow

`SourceSession` should replace `cache_buffer` with:

```elixir
cache_sink: nil | ImagePlug.Cache.Sink.t()
```

`nil` means this response doesn't cache. Use no no-op sink.

Prepare flow:

1. Resolve output.
2. Open a cache sink if the request has a cache key.
3. Create the encoder stream.
4. Pull the first encoded chunk.
5. Write the first chunk to the sink.
6. Return prepared response metadata and the first chunk.

Next flow:

1. Resume the suspended encoder continuation once.
2. If it returns a chunk, write that chunk to the sink.
3. Return the chunk to `Response.Sender`.
4. If it reaches normal completion, commit the sink and return `:done`.

Failure flow:

- explicit cancel aborts the sink
- owner death aborts the sink
- client close causes `Response.Sender` to call cancel, which aborts the sink
- source, decode, output, or encode failure aborts the sink
- cache sink write failure drops or aborts the sink and continues delivery
- cache sink commit failure emits cache write telemetry and still returns `:done`

This preserves the existing delivery rule: cache state must not decide whether an
already-successful image delivery becomes an HTTP failure.

## Delivery Ordering

`SourceSession` should write each chunk to the sink before returning it to the
sender. That keeps cache staging from lagging behind bytes that ImagePlug has
already handed to the response layer.

The sender calls `next/0` only after it successfully delivers the previous
chunk. When `SourceSession.next/1` observes stream completion, the sender has
delivered every returned chunk. That's the commit point.

If writing a chunk to the sink fails, cache staging should stop for that
response. Return the chunk to the sender unless the image stream itself failed.

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

Abort:

- close the body file if open
- remove temporary body and metadata files

Readers should continue to use committed metadata paths only. They should never
look for temporary files, so staged writes remain invisible.

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

Adapters can add asynchronous part uploads inside the S3 adapter later. That
shouldn't change the `SourceSession` contract.

## Size Limit Behavior

`:max_body_bytes` remains a cache storage limit, not a response delivery limit.

The cache coordinator should track written byte count. If a write would cross
the limit:

- stop cache staging for this response
- abort or drop the sink
- emit `cache: :write_skipped` with `reason: :too_large`
- continue HTTP response delivery

The sink shouldn't rely on every adapter duplicating this limit correctly.

## Telemetry

Keep the existing cache event shape where possible:

```text
[:image_plug, :cache, :write, :start]
[:image_plug, :cache, :write, :stop]
```

Use `[:cache, :write]` for sink commit attempts.

Use `[:cache, :tee]` for staging outcomes that don't call the adapter commit:

- `cache: :write_skipped`, `reason: :too_large`
- `cache: :abandoned`, `reason: :cancelled`
- `cache: :abandoned`, `reason: :owner_down`
- `cache: :abandoned`, `reason: :stream_error`
- `cache: :write_error` when staging failed before commit and delivery
  continued

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

The existing `Cache.put/3` API can stay for whole-body writes if tests or helper
code still need it. The prepared-stream cache miss path should use the sink.

## Open Questions For Implementation

- Whether filesystem commit should rename body first or metadata first. Readers
  currently discover entries through metadata, so metadata should become visible
  last.
- Whether temporary files should live in the final partition directory or a
  dedicated temp directory under the cache root. The final partition directory
  keeps rename atomic on a single filesystem.
- Whether abort failures need telemetry and logs. They shouldn't
  affect HTTP delivery.
- Whether `Cache.put/3` should be rewritten internally through a sink after
  the sink path lands. That can wait unless duplication becomes awkward.
