# Source Stream Lifecycle Boundary Design

## Decision

Keep ImagePlug's source abstraction. Don't replace it wholesale with `Image.from_req_stream/2`.

Shrink the current stream infrastructure instead:

- Source owns source identity, adapter fetch policy, body limits, chunk validation, and HTTP/S3 Req details.
- Request owns the `Vix`/Image linked-process lifecycle hazard.
- Transform stays source-agnostic.

The implementation should remove request-mailbox coupling from `ImagePlug.Source.WrappedStream`, stop trapping exits in the Plug request process, and add a private monitored worker under `ImagePlug.Request`. That worker must own the whole cache-miss or no-cache source path, not just `Image.open/2`.

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

Add a private module:

```elixir
ImagePlug.Request.SourceStreamBoundary
```

Don't export it from `ImagePlug.Request`.

`SourceStreamBoundary.run/1` starts a monitored worker. The worker sets `trap_exit` while it runs the whole source-dependent function. The caller only monitors the worker and never changes its own process flags.

Use an unlinked worker:

- start it with `spawn_monitor`
- tag the result message with a unique reference
- call `Process.demonitor(ref, [:flush])` after receiving a result
- don't use `Task.async`, because it links the worker to the caller

The boundary converts these failures into `{:error, {:source, reason}}`:

- a direct `%ImagePlug.Source.StreamError{}` raise
- a linked process exit with `%ImagePlug.Source.StreamError{}`
- a worker crash caused by `%ImagePlug.Source.StreamError{}`

Other exits must not disappear. With `trap_exit: true`, every linked exit becomes a mailbox message. For linked exits that aren't `%ImagePlug.Source.StreamError{}`, the boundary must re-exit, raise, or return through the existing non-source error path.

Source stream exits should dominate generic image errors. The worker should check for trapped `%ImagePlug.Source.StreamError{}` exits after source-consuming stages and immediately before it sends any success or non-source error result to the caller. If a checkpoint finds a source stream exit, return `{:error, {:source, reason}}`.

The boundary isn't a general exception blanket.

### Transform

Transform shouldn't learn about source streams, Req, or `%ImagePlug.Source.StreamError{}`.

Materialization remains a transform concern, but the request boundary decides when it must materialize before returning from the worker.

## Boundary Invariant

A source-backed `VipsImage` must stay in the process that owns the source stream until that process materializes it.

Two designs preserve this invariant:

1. Run fetch, decode, transform, final output negotiation, and final materialization inside the boundary worker. Return a materialized final state.
2. Run response encoding inside the boundary worker and stream encoded bytes back to the Plug request process.

Use option 1 now. It's simpler and fixes the race without redesigning response delivery.

Option 2 is the later performance design if final materialization costs too much for large non-cached responses.

## Runner Flow

Keep parser, planner, source resolution, cache config validation, and cache lookup outside the stream boundary. None of those steps should fetch or consume source bytes.

For cache hits, return the cache entry without entering the stream boundary.

For cache misses and requests that skip the cache, enter the stream boundary before source fetch. The boundary must wrap `Runner.process_request/4` or the whole source-dependent path. Don't put the boundary only around `Processor.process_source/3`. Automatic output can split decode from transform and final-alpha inspection.

Inside the boundary:

- fetch source
- decode source
- inspect source format
- resolve automatic output that depends on source format
- execute transforms
- inspect final alpha when automatic output requires it
- materialize final state before returning

Final materialization for streamed-source states is unconditional in this design. Don't reuse the current access-based `:sequential` gate. Random-access decode paths can still hold source-backed libvips state, so they must also materialize before the state crosses the worker boundary.

After the boundary returns a materialized final state, cache encoding and normal response delivery can stay in the caller process.

This keeps the initial implementation conservative. The design intentionally trades some memory and latency for a hard safety boundary.

## Error Behavior

Source stream errors should return source errors:

```elixir
{:error, {:source, reason}}
```

The Plug layer should keep returning the existing user-visible source failure response, for example status `422` and `"invalid image source"` in the current request safety tests.

Decode errors that aren't source stream failures should remain decode errors:

```elixir
{:error, {:decode, reason}}
```

Materialization errors should continue to follow existing materialization error mapping. Don't introduce source-specific errors into transform materialization tests.

If final materialization returns a generic image error and the worker also observes a trapped `%ImagePlug.Source.StreamError{}`, return the source error. That preserves the request-safety contract when libvips reports a generic load failure for an upstream stream failure.

## Performance Implications

The conservative boundary forces materialization before the final state leaves the worker. That has costs:

- more native memory pressure for large decoded images
- later time to first byte for non-cached, cache-skip, and explicit-format streaming responses
- less use of libvips laziness on some one-pass pipelines

The benefit is a clear failure contract: ImagePlug sees source read failures before it returns a successful processed image from the boundary.

Don't materialize earlier than needed:

- not before parser or planner validation
- not before cache lookup
- not in `Source.fetch/3`
- not inside the body stream wrapper
- not between every transform operation
- not on cache hits

Materialize when a source-backed image would otherwise cross the request worker boundary.

For the first implementation, assume every successful state produced from a fetched source stream is source-backed and materialize it. Tracking whether a state is still source-backed can come later if measurements show the unconditional copy costs too much.

Cache misses can still encode twice. Today the cache path may encode up to the cache body limit, skip cache on `:too_large`, and then encode again for normal response delivery. Final materialization adds another full-pixel copy before those encodes. Keep that as known performance debt for option 1.

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

## Test Hooks

Shrink test-only runtime hooks while touching this area.

Prefer source adapters, controlled streams, boundary fixtures, and transform/materializer modules wired through existing internal boundaries over generic runtime hooks. Remove `:image_materializer` and update tests to use the narrower `:image_materializer_module` only if the hook remains useful as an internal extension point.

Check `:image_open_module`. If tests can prove the boundary through source adapters and controlled streams, remove the hook. If it remains, document it as test/internal-only and keep it out of the public option surface.

## Tests

Add tests that prove behavior, not private mechanics.

Add:

- `ImagePlug.Request.SourceStreamBoundary` unit tests for direct `%Source.StreamError{}` raises
- boundary tests for linked reader exits
- a Plug-level regression where a linked reader fails after decode has started and the response is still a source error
- Runner coverage for automatic output negotiation when the failure happens after source-format decode but before final delivery
- tests where the source failure happens during final-alpha negotiation
- tests where the source failure happens during final materialization
- tests that non-source linked exits don't get swallowed
- tests that the caller's `trap_exit` flag stays unchanged
- tests that successful worker results flush stale `DOWN` messages from the caller mailbox
- no-cache and cache-over-limit tests that document the option 1 performance shape

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

## Non-Goals

Don't redesign response delivery in this change.

Don't replace `Source.ReqStream` with `Image.from_req_stream/2` in this change.

Don't make source streaming public API.

Don't change imgproxy encrypted URL behavior as part of this work.

Don't preserve tidy errors for impossible internal misuse introduced only by old helper functions.

## Later Work

Benchmark these variants before optimizing the boundary:

- current PR #86 fix
- monitored worker with final materialization
- monitored worker with selective materialization
- boundary-owned encoded streaming
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

If materialization is too expensive, move encoded response production into the monitored worker instead of weakening the lifecycle invariant.

Before building boundary-owned encoded streaming, write its protocol down. It needs to define:

- how the worker sends encoded chunks to the Plug process
- pressure control between `Plug.Conn.chunk/2` and the worker
- worker cancellation when the client disconnects
- source errors before headers versus after the first chunk
- encode errors before headers versus after the first chunk
- cache teeing or buffering when cache write and response delivery both need the encoded bytes
