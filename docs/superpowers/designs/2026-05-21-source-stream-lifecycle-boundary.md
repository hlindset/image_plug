# Source Stream Hybrid Lifecycle Boundary Design

## Decision

Keep ImagePlug's source abstraction. Don't replace it wholesale with `Image.from_req_stream/2`.

Use a hybrid response contract:

- Before response delivery starts, ImagePlug returns clean HTTP errors for source, decode, output, and cache failures.
- After response delivery starts, late source, decode, or encode failures are stream failures. ImagePlug records telemetry, aborts delivery, and never writes a cache entry for partial output.

This sacrifices HTTP-level error determinism for late lazy failures. In return, ImagePlug avoids forcing a full-pixel materialization before every streamed response.

Shrink the current stream infrastructure:

- Source owns source identity, adapter fetch policy, body limits, chunk validation, and HTTP/S3 Req details.
- Request owns the `Vix`/Image linked-process lifecycle hazard.
- Transform stays source-agnostic.

The implementation should remove request-mailbox coupling from `ImagePlug.Source.WrappedStream`, stop trapping exits in the Plug request process, and add a private boundary under `ImagePlug.Request` for source-backed decode and encode work.

## Problem

`Image.open/2` can consume an enumerable through `Vix`. `Vix` reads enumerable input from a linked process. If the source enumerable raises `%ImagePlug.Source.StreamError{}`, that linked process can exit after `Image.open/2` has returned control to ImagePlug.

The current PR #86 fix makes the failure less likely by:

- setting `trap_exit` in `ImagePlug.Request.Processor`
- forwarding source stream errors from `WrappedStream` to the request process
- doing a zero-time mailbox check after `Image.open/2`

That still has two bad properties:

- The Plug request process temporarily traps exits. That changes how unrelated linked exits behave while the flag remains active.
- The zero-time mailbox check only sees messages already delivered. A linked source reader can fail just after the check.

The deeper issue is lifecycle ownership. A source-backed libvips image can still read from the source after `Image.open/2`, during transform execution, source-format fallback, alpha inspection, cache encoding, or response encoding.

The strict model tried to force that work before response delivery by materializing the final image. The hybrid model accepts that some failures happen during delivery and treats them as stream failures.

## Hybrid Contract

ImagePlug has two phases for a cache miss or no-cache request.

### Before Delivery Starts

ImagePlug can still choose the HTTP status and response body. Failures in this phase return the existing clean errors.

Examples:

- parser or planner validation failure
- source resolution failure
- denied source host
- bad source status before body streaming
- output negotiation failure
- cache lookup or cache write failure when `fail_on_cache_error: true`
- source-format or final-alpha inspection failure when output negotiation needs it before headers
- memory cache encoding failure before a response starts

### After Delivery Starts

Once ImagePlug commits response headers, it can't replace the response with a `422` or `500`. For chunked delivery, `Plug.Conn.send_chunked/2` is the commit point, not the first successful body chunk.

Failures in this phase should:

- abort response delivery
- emit telemetry with the source/decode/output reason where available
- avoid writing a cache entry
- let the client observe a failed or incomplete image response

This applies to source body limit errors, source timeouts, truncated bodies, late decode failures, and encode failures that happen after ImagePlug commits response headers.

## Why Not `Image.from_req_stream/2`

`Image.from_req_stream/2` is a useful convenience API, but it doesn't own ImagePlug's source contract.

ImagePlug needs behavior that sits outside `image`:

- allowed host checks before fetch
- sanitized Req options and headers
- deterministic source identity for cache keys
- redirect, connect, pool, and receive timeout policy
- source error taxonomy such as `{:source, :bad_status}` and `{:source, :body_too_large}`
- `max_body_bytes` while the source reader consumes the body
- HTTP, S3, file, and custom adapters behind one source contract
- parser and planner failures before source fetch or cache access

Direct `Image.from_req_stream/2` also doesn't remove the `Vix` linked-process issue. It still reaches the same enum-backed `Vix` read path for streamed input.

The right use of Req is narrower: use Req request, response, and error steps inside HTTP/S3 source adapters where they reduce local code. Req shouldn't become the ImagePlug request lifecycle boundary.

## Ownership

### Source

Source should return a `%ImagePlug.Source.Response{stream: enumerable}` after adapter fetch. That stream is internal to ImagePlug.

Source owns:

- adapter validation
- source resolution
- cache identity material
- fetch policy
- HTTP/S3 request construction
- body byte limits
- binary chunk validation
- normalization of adapter enumerable failures into `%ImagePlug.Source.StreamError{}`

Source must not know about request processes. In particular:

- remove `WrappedStream.error_receiver`
- remove `Source.forward_stream_errors/2`
- make response wrapping a private implementation detail of `Source.fetch/3`

`Source.ReqStream` stays for now. It preserves behavior that `Image.from_req_stream/2` doesn't currently expose cleanly: 2xx handling, cancellation, timeout mapping, and ImagePlug source errors. A later change can move more HTTP policy into Req steps.

Narrow `WrappedStream`, and rename it to `ImagePlug.Source.BodyStream` in the implementation if the churn is acceptable. Its job should be exactly:

- accept only binary chunks
- count bytes against `max_body_bytes`
- preserve explicit `%ImagePlug.Source.StreamError{}`
- turn unexpected enumerable errors into `%ImagePlug.Source.StreamError{reason: :stream_exception}`
- clean up correctly when enumeration halts

### Request

Request owns `Vix` lifecycle isolation.

Add a private module under `ImagePlug.Request`, for example:

```elixir
ImagePlug.Request.SourceStreamBoundary
```

Don't export it from `ImagePlug.Request`.

The boundary should support two modes.

### Pre-Response Mode

Use this when ImagePlug must finish source-backed work before it can decide the response.

Examples:

- source-format inspection for `format:auto`
- final-alpha inspection for automatic output selection
- cache memory encoding before writing a cache entry

This mode runs in an unlinked monitored worker. The worker can set `trap_exit` while it owns source-backed work. The caller only monitors the worker and never changes its own process flags.

Use an unlinked worker:

- start it with `spawn_monitor`
- tag the result message with a unique reference
- call `Process.demonitor(ref, [:flush])` after receiving a result
- don't use `Task.async`, because it links the worker to the caller

Before response delivery starts, the boundary converts `%ImagePlug.Source.StreamError{}` raises or linked exits into `{:error, {:source, reason}}`.

Other exits must not disappear. With `trap_exit: true`, every linked exit becomes a mailbox message. For linked exits that aren't `%ImagePlug.Source.StreamError{}`, the boundary must re-exit, raise, or return through the existing non-source error path.

Exit handling must distinguish normal helper exits from failures:

- ignore or drain `{:EXIT, pid, :normal}` from boundary-owned linked helpers
- map `%ImagePlug.Source.StreamError{}` exits to source errors before header commit
- map `%ImagePlug.Source.StreamError{}` exits to stream-failure telemetry after header commit
- re-emit abnormal non-source exits instead of ignoring them

### Streaming Mode

Use this for response delivery that should stay lazy.

The source-backed fetch, decode, transform, output negotiation, and encode work runs inside one long-lived boundary worker. The Plug request process still owns `Plug.Conn` and calls `Plug.Conn.send_chunked/2` and `Plug.Conn.chunk/2`.

The worker must be demand-driven. It shouldn't eagerly read `Image.stream!/2` and push chunks into the request process mailbox.

Use this protocol shape:

1. The caller starts an unlinked monitored worker with a unique request reference.
2. The worker performs source-backed pre-delivery work needed to decide headers, content type, output policy, and status.
3. The worker returns `{:ready, ref, response_metadata}` or `{:pre_error, ref, phase, reason}`.
4. The caller sends headers. If `send_chunked/2` fails, the caller sends `{:cancel, ref}` to the worker.
5. After headers commit, the caller sends `{:next, ref}`.
6. The worker produces at most one encoded chunk and replies with `{:chunk, ref, binary}`, `{:done, ref, cache_result}`, or `{:stream_failed, ref, phase, reason}`.
7. The caller calls `Plug.Conn.chunk/2` for each chunk. On `{:ok, conn}`, it requests the next chunk. On `{:error, reason}`, it cancels the worker and treats delivery as closed.

Before headers commit, worker failures can still become clean HTTP errors.

After headers commit, worker failures are stream failures:

- source failures emit source telemetry and abort delivery
- decode failures emit decode telemetry and abort delivery
- output failures emit output telemetry and abort delivery
- skip cache writes

The worker shouldn't send source-backed `VipsImage` state back to the caller in streaming mode. It sends encoded bytes or a terminal result.

### Transform

Transform shouldn't learn about source streams, Req, or `%ImagePlug.Source.StreamError{}`.

Materialization remains a transform concern for explicit transform boundaries, not a global request-delivery rule.

## Boundary Invariant

A source-backed `VipsImage` must not escape into normal response delivery as a caller-owned state.

Handle it in either of these ways:

1. A pre-response worker consumes it and returns a memory/cache result or a clean error.
2. A streaming worker owns it until encode completes or fails, and only sends encoded chunks to the Plug process.

Don't force final `copy_memory/1` merely to make late failures look like pre-response errors. That was the strict model. The hybrid model treats late delivery failures as stream failures.

Pre-response inspection must not return `%ImagePlug.Request.Processor.Decoded{}` or any other struct that contains a source-backed `VipsImage`. It can return scalar metadata such as source format, alpha need, resolved output, headers, or a complete memory/cache result. If the response will stream, the same long-lived worker should continue into streaming mode instead of handing the decoded image back to the caller.

Keep materialization where it has its own semantic job:

- between explicit plan pipelines
- when output negotiation must inspect image data
- before writing a cache entry, if the cache path uses memory output

## Runner Flow

Keep parser, planner, source resolution, cache config validation, and cache lookup outside the stream boundary. None of those steps should fetch or consume source bytes.

For cache hits, return the cache entry without entering the stream boundary.

For cache misses and requests that skip the cache, enter the boundary before source fetch. The boundary must wrap the source-dependent path, not only `Processor.process_source/3`. Automatic output can split decode from transform and final-alpha inspection.

Recommended flow:

- Resolve any output policy that doesn't need source bytes.
- Start one source worker for the cache-miss or no-cache source path.
- Let the worker perform any source-format or final-alpha work needed before headers.
- If the response should stream, keep the same worker alive for demand-driven response encoding.
- If ImagePlug should populate cache while streaming, tee encoded chunks inside the worker and commit cache only after complete encode success.

When the cache tee exceeds the cache body limit, disable cache buffering and continue response streaming from the same encode stream. Don't restart from a consumed source-backed image.

When `fail_on_cache_error: true`, keep the old pre-response cache behavior for cacheable misses: encode and write the cache entry before committing response headers. Hybrid streaming can't report a cache write failure as an HTTP error after headers commit.

## Error Behavior

Before response delivery starts, source stream errors return source errors:

```elixir
{:error, {:source, reason}}
```

Decode errors that aren't source stream failures remain decode errors:

```elixir
{:error, {:decode, reason}}
```

After response headers commit, these same failures become stream failures. The user-visible status and headers stay whatever was already sent.

Represent stream failures internally with phase and reason, not only an HTTP error tuple. Useful phases include:

- `:source`
- `:decode`
- `:output`
- `:cache`
- `:client_closed`

Useful source reasons include:

- `:bad_status`
- `:receive_timeout`
- `:transport`
- `:body_too_large`
- `:invalid_stream_chunk`
- `:stream_exception`

Telemetry should distinguish:

- source stream failure before delivery
- source stream failure after delivery starts
- decode failure before delivery
- decode failure after delivery starts
- output failure before delivery
- output failure after delivery starts

Cache behavior stays strict: cache only successful complete encoded responses.

## Performance Implications

The hybrid boundary avoids unconditional final materialization. That preserves the main benefits of streaming for no-cache, cache-skip, and large output paths:

- lower peak native memory than full-pixel materialization
- earlier first response chunk
- more use of libvips lazy execution

The cost is an honest HTTP contract. Late failures after response start no longer become clean `422` or `500` responses.

For cacheable misses, use two modes:

- Default cache fail-open mode can tee the response stream into a cache buffer and commit only after EOF.
- `fail_on_cache_error: true` uses pre-response cache encoding and write before headers commit.

The streaming tee avoids the current encode-twice path when cache output is too large. If the cache buffer crosses the limit, discard the buffer and keep streaming the response.

## Req Steps

Req steps are a good fit for HTTP/S3 implementation details:

- setting `into: :self`
- disabling retry
- applying redirect policy
- preserving connect, pool, and receive timeout defaults
- sanitizing user-supplied request options
- mapping bad status and transport errors before stream construction where possible
- signing S3 requests

Req steps aren't the system boundary. They can't own source identity, cache behavior, non-HTTP adapters, byte counting during stream consumption, or `Vix` linked reader exits.

Keep Req usage inside source adapters or a private source transport helper.

Sanitize `req_options` by allowlist where possible. Reject or drop Req pipeline, adapter, request-step, response-step, and error-step options that can bypass ImagePlug's URL, redirect, retry, status, signing, or source error policy.

Do this before extracting shared Req transport. Don't move HTTP/S3 transport into `ReqTransport` until the option allowlist blocks Req adapter and step overrides.

## Req Transport Follow-Up

Extract shared Req setup after the lifecycle boundary fix lands.

Create a private source module such as:

```elixir
ImagePlug.Source.ReqTransport
```

`ImagePlug.Source.HTTP` and `ImagePlug.Source.S3` can call it, but it should still return `%ImagePlug.Source.Response{stream: enumerable}` through the existing source contract. Request and Transform shouldn't see `%Req.Request{}`, `%Req.Response{}`, `%Req.Response.Async{}`, or Req stream messages.

The actual `Req.get(..., into: :self)` call must still happen inside the process that enumerates the body. Don't pre-open a streamed Req response in `Source.fetch/3` and pass it to another process. Req expects the creating process to read streamed response messages, while `Vix` reads enumerable input from a linked reader process.

Move duplicated Req transport behavior into the shared helper:

- force `method: :get`
- force `into: :self`
- force `retry: false`
- apply the adapter's redirect policy
- merge connect, pool, and receive timeout defaults
- normalize non-2xx status into source errors
- normalize Req transport errors into source errors
- cancel streamed responses when enumeration halts or fails

Keep adapter policy in the adapters:

- HTTP allowed-host checks
- HTTP cache-sensitive header stripping
- S3 endpoint, bucket, key, and revision validation
- S3 credential lookup
- S3 signing options
- S3 signed-header stripping

Don't move `max_body_bytes` into Req transport. The limit applies while libvips consumes the source stream, so the body stream wrapper should keep counting chunks at enumeration time.

This follow-up shouldn't change behavior. Treat it as extraction first, then consider Req request, response, or error steps where they replace local code without weakening ImagePlug's source error contract.

Source fetch telemetry shouldn't claim that lazy HTTP body fetch has completed. Either rename the existing source fetch span to stream construction semantics or add worker-owned telemetry for source open and source body consumption.

## Test Hooks

Shrink test-only runtime hooks while touching this area.

Prefer source adapters, controlled streams, boundary fixtures, and transform/materializer modules wired through existing internal boundaries over generic runtime hooks. Remove `:image_materializer` and update tests to use the narrower `:image_materializer_module` only if the hook remains useful as an internal extension point.

Check `:image_open_module` and `:image_module`. If tests can prove the boundary through source adapters, controlled streams, and boundary fixtures, remove the hooks. If they remain, document them as test/internal-only and keep them out of the public option surface.

## Tests

Add tests that prove behavior, not private mechanics.

Add:

- boundary tests for direct `%Source.StreamError{}` raises before response starts
- boundary tests for linked reader exits before response starts
- tests that non-source linked exits don't get swallowed
- tests that the caller's `trap_exit` flag stays unchanged
- tests that successful worker results flush stale `DOWN` messages from the caller mailbox
- tests where `format:auto` source-format failures return clean errors before delivery
- tests where final-alpha negotiation failures return clean errors before delivery
- streaming tests where source failure after headers commit aborts delivery instead of returning `422`
- streaming tests where decode or output failure after headers commit aborts delivery instead of returning a replacement body
- cache tests that partial or failed streamed output is never written
- cache-over-limit tests that fall back to streaming mode without final image materialization
- cache tee tests that commit only after complete encode success
- client disconnect tests that cancel the source worker and discard cache buffers
- tests for `fail_on_cache_error: true` preserving pre-response cache error behavior

Keep existing Source tests for:

- body byte limit
- non-binary chunks
- upstream enumerable exception normalization
- cleanup on halt

Delete or rewrite tests that assert:

- `{:source_stream_error, ...}` mailbox messages
- direct public use of `Source.wrap_response/2`
- the old `:image_materializer` test hook

Source body wrapper tests should exercise wrapping through `Source.fetch/3` with a small test adapter that returns controlled streams. Don't call `Source.wrap_response/2` directly after it becomes private.

Race tests need explicit gates. Don't use sleeps. Use `Process.monitor/1`, `send`/`receive` handshakes, and controlled stream or reader processes that fail only after a named stage starts. At least one regression should force the old zero-time mailbox check to return success before releasing the linked source failure.

Plug tests can verify response shape, status, and that ImagePlug sends no replacement body after headers commit. They can't prove a real socket abort because `Plug.Adapters.Test.Conn` concatenates chunks. Add a boundary protocol test for demand and cancellation, plus at least one real HTTP client or raw socket test for incomplete or closed streamed responses.

## Non-Goals

Don't replace `Source.ReqStream` with `Image.from_req_stream/2` in this change.

Don't make source streaming public API.

Don't change imgproxy encrypted URL behavior as part of this work.

Don't preserve tidy errors for impossible internal misuse introduced only by old helper functions.

Don't guarantee clean HTTP error bodies after response delivery starts.

## Later Work

Benchmark these variants before optimizing the boundary:

- current PR #86 fix
- hybrid worker-owned response streaming
- pre-response memory cache encoding plus streaming fallback
- `Image.from_req_stream/2` as a baseline

Measure:

- total response time
- time to first byte
- peak native memory
- BEAM binary memory
- request process mailbox length
- cache miss with cache write
- non-cached response delivery
- upstream abort, timeout, body too large, invalid chunk, and client disconnect

If worker-owned response streaming is too complex, reconsider strict pre-response materialization as an opt-in mode, not the default.
