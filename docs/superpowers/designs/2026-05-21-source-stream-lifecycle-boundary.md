# Source Stream Hybrid Lifecycle Boundary Design

## Decision

Keep ImagePlug's source abstraction. Don't replace it wholesale with `Image.from_req_stream/2`.

Use a hybrid response contract as the target design:

- Before response delivery starts, ImagePlug returns clean HTTP errors for source, decode, output, and cache failures.
- After response delivery starts, late source, decode, or encode failures are stream failures. ImagePlug records telemetry, aborts delivery, and never writes a cache entry for partial output.

This sacrifices HTTP-level error determinism for late lazy failures. In return, ImagePlug avoids forcing a full-pixel materialization before every streamed response.

Shrink the current stream infrastructure:

- Source owns source identity, adapter fetch policy, body limits, chunk validation, and HTTP/S3 Req details.
- Request owns the `Vix`/Image linked-process lifecycle hazard.
- Transform stays source-agnostic.

The implementation should remove request-mailbox coupling from `ImagePlug.Source.WrappedStream`, stop trapping exits in the Plug request process, and add a private boundary under `ImagePlug.Request` for source-backed decode and encode work.

Don't build the whole target design in one change. The first slice should fix the source stream exit race with a pre-response worker boundary and remove request-mailbox coupling. Leave worker-owned response streaming, cache teeing, and Req transport extraction for later slices.

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

Before committing headers for chunked delivery, ImagePlug should prove that the encoder can produce the first chunk. Empty output streams and failures while producing the first chunk remain clean pre-response output errors.

## Public Contract

Hybrid delivery is user-visible behavior, not only an internal implementation detail.

Public docs should explain:

- `200` means ImagePlug accepted the request and started delivering an image; it doesn't prove every lazy source read and encode step has completed.
- Clients must treat socket close, incomplete transfer, or client-side image decode failure as request failure even when the HTTP status is `200`.
- ImagePlug writes cache entries only after a complete successful encode.
- `fail_on_cache_error: true` keeps cache write errors in the pre-response phase for cacheable misses.
- Late failures after headers commit are observable through telemetry, not through a replacement HTTP error body.

Public docs should also include a compact status table. Cover parser failures, source resolution and fetch failures, source body limits, decode failures, pixel limits, encode failures, cache fail-open/fail-closed behavior, and post-commit stream failures.

Don't add a strict delivery option in the first slice. If real users need deterministic HTTP errors for all source/decode/encode failures, add that later as an explicit mode with clear memory and latency tradeoffs.

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
- enforce `max_body_bytes`
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

A final zero-time linked-exit drain inside the worker is only a cleanup check. It can convert source exits already delivered to the worker mailbox, but it isn't the correctness boundary. Correctness comes from the worker either returning a source error from the source-dependent operation or continuing to own the source-backed lifecycle in streaming mode.

Don't replace that cleanup check with "wait until every linked process exits." `Vix` may keep linked reader processes alive after `Image.open/2` returns on successful paths.

A quiescence wait can hang valid requests. If a late source-backed failure matters after `Image.open/2`, keep the source-backed lifecycle inside the worker through encode or delivery. Don't guess that all linked processes should exit before returning.

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
3. The worker produces the first encoded chunk before headers commit.
4. The worker returns `{:ready, ref, response_metadata, first_chunk}` or `{:pre_error, ref, phase, reason}`.
5. The caller sends headers. If `send_chunked/2` fails, the caller sends `{:cancel, ref}` to the worker.
6. The caller sends the prepared first chunk with `Plug.Conn.chunk/2`.
7. After each successful chunk, the caller sends `{:next, ref}`.
8. The worker produces at most one encoded chunk and replies with `{:chunk, ref, binary}`, `{:done, ref, cache_result}`, or `{:stream_failed, ref, phase, reason}`.
9. On `{:error, reason}` from `Plug.Conn.chunk/2`, the caller cancels the worker and treats delivery as closed.

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

## First Implementation Slice

The first slice shouldn't change `Response.Sender`, chunk delivery, cache teeing, or Req transport.

Build only the pre-response source stream boundary:

- add private `ImagePlug.Request.SourceStreamBoundary`
- run existing cache-miss and cache-skip source processing inside an unlinked monitored worker
- preserve the caller's `trap_exit` flag
- stop the worker when the caller exits
- convert `%ImagePlug.Source.StreamError{}` linked exits to `{:error, {:source, reason}}`
- re-emit or return non-source failures through existing error paths
- remove request-process `trap_exit`
- remove `Source.forward_stream_errors/2`
- remove `WrappedStream.error_receiver`
- keep existing cache timing and response delivery behavior

This slice fixes the PR #86 source-stream exit race without taking on worker-owned response streaming. It may still use existing pre-response materialization where the current code already does so. It also may still return a final `%ImagePlug.Transform.State{}` that contains a source-backed `VipsImage` on current random-access paths. That's a known first-slice limitation, not the target invariant. Later slices should move response encode into streaming mode so the worker sends encoded bytes instead of caller-owned source-backed image state.

The first slice also tightened two supporting edges:

- `WrappedStream` preserves downstream consumer raises, throws, and invalid reducer returns instead of turning them into source stream errors. It uses a per-reduction reference so an upstream enumerable can't forge the internal consumer-failure transport.
- `SourceStreamBoundary` replays non-source raises and throws in the caller with `:erlang.raise/3`. The stack trace still points at worker execution, because the failure happened there.

## Follow-Up Slices

Build the rest as separate pull requests. Each slice should have its own implementation plan and tests.

### Worker-Owned Response Streaming

Move response encoding into the long-lived source worker. The worker owns source-backed image state through encode completion or failure and sends only encoded chunks or terminal results to the Plug request process.

This slice should:

- produce the first encoded chunk before `Plug.Conn.send_chunked/2`
- keep the worker demand-driven with one encoded chunk per `:next`
- treat pre-header source, decode, and output failures as clean errors
- treat post-header source, decode, and output failures as stream aborts with telemetry
- keep source-backed `VipsImage` state inside the worker until encode finishes or fails
- avoid "wait for all linked processes" as a completion rule; successful `Vix` paths may keep links alive
- add protocol tests plus a real socket or raw client test for incomplete streamed responses
- avoid cache teeing; keep cacheable misses on the existing pre-response cache path if needed

Cover these source-backed failure timings:

- during decode
- immediately after the final source chunk
- after consumer halt
- after suspend and continuation
- during response streaming or encode after headers commit

The expected post-header behavior is telemetry plus aborted delivery, not a replacement HTTP error body.

### Streaming Cache Tee

Add cache population to the streaming path after worker-owned response streaming is stable.

This slice should:

- tee encoded chunks into a cache buffer or streamed cache writer
- commit cache only after complete successful encode
- discard partial cache data on source, decode, output, cache, or client failure
- drop cache buffering and keep streaming when output crosses the cache body limit
- keep `fail_on_cache_error: true` on the pre-response cache path
- define any cache body abstraction and adapter migration outside source lifecycle work

### Req Transport Extraction

Move shared HTTP/S3 Req setup after source lifecycle behavior is stable.

This slice should:

- keep `%ImagePlug.Source.Response{stream: enumerable}` as the source contract
- keep Request and Transform away from Req structs and stream messages
- sanitize `req_options` so callers can't override adapters or Req steps that bypass ImagePlug policy
- keep `Req.get(..., into: :self)` in the process that enumerates the body
- add the process-ownership comment near that call in `ImagePlug.Source.ReqStream`
- avoid moving `max_body_bytes` into Req transport

### Public Contract Docs And Issue Triage

Document hybrid delivery after worker-owned response streaming changes public behavior.

This slice should:

- explain pre-response clean errors versus post-commit stream failures
- state that `200` means ImagePlug accepted the request and started delivery, not that lazy source reads and encoding completed
- tell clients to treat socket close, incomplete transfer, or client-side decode failure as request failure
- document that cache entries commit only after complete successful encode
- include a compact status table for parser, source, decode, limit, output, cache, and post-commit failures
- update the related GitHub issues after merge without using `Closes #...` unless the issue is fully solved

### Error Taxonomy Cleanup

Do this when worker-owned streaming introduces explicit post-commit failures. That's the point where source, decode, materialize, output, cache, and client-close reasons need one audit path.

This slice should:

- keep pre-response HTTP error mapping compatible with `ImagePlug.Response.Sender`
- represent post-commit failures as `{phase, reason}` data for telemetry and diagnostics
- decide whether intermediate materialization failures remain `{:decode, reason}` or become `{:materialize, reason}` / `{:transform, {:materialize, reason}}`
- decide whether cache write failures stay as processing errors with response headers or become a separate runner-level cache error
- avoid adding a taxonomy module until two or more call sites would actually use it

### Runner And Cache Flow Extraction

Do this after worker-owned streaming and cache teeing have real code. `ImagePlug.Request.Runner` is still coherent while it only coordinates cache lookup, output policy, processor invocation, cache write, and delivery shape.

This slice should:

- move cache lookup, fail-open miss handling, cache write, and cache-entry validation only if the streaming tee adds more cache branches
- keep source resolution and parser/planner validation outside cache orchestration
- keep response headers attached to processing errors that still need `ImagePlug.Response.Sender` handling
- avoid moving output negotiation or source lifecycle code into a cache helper

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

The first slice doesn't get every benefit. It keeps current response delivery and cache behavior while it fixes process ownership. Treat the hybrid streaming worker and cache tee as follow-up work.

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

Move shared Req setup after the lifecycle boundary fix lands.

Create a private source module such as:

```elixir
ImagePlug.Source.ReqTransport
```

`ImagePlug.Source.HTTP` and `ImagePlug.Source.S3` can call it, but it should still return `%ImagePlug.Source.Response{stream: enumerable}` through the existing source contract. Request and Transform shouldn't see `%Req.Request{}`, `%Req.Response{}`, `%Req.Response.Async{}`, or Req stream messages.

The actual `Req.get(..., into: :self)` call must still happen inside the process that enumerates the body. Don't pre-open a streamed Req response in `Source.fetch/3` and pass it to another process. Req expects the creating process to read streamed response messages, while `Vix` reads enumerable input from a linked reader process.

When this extraction happens, add a short code comment near the `Req.get(..., into: :self)` call in `ImagePlug.Source.ReqStream`. The process-ownership rule is easy to break during a later refactor and belongs next to the transport code, not only in this design document.

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
- tests that downstream consumer raises, throws, and invalid reducer returns aren't reported as source stream errors
- tests that upstream throws shaped like internal consumer-failure transport are still source stream failures
- tests that the caller's `trap_exit` flag stays unchanged
- tests that the worker exits when the caller exits
- tests that successful worker results flush stale `DOWN` messages from the caller mailbox
- tests where `format:auto` source-format failures return clean errors before delivery
- tests where final-alpha negotiation failures return clean errors before delivery
- streaming tests where source failure after headers commit aborts delivery instead of returning `422`
- streaming tests where decode or output failure after headers commit aborts delivery instead of returning a replacement body
- tests where empty output or first-chunk encode failure returns a clean output error before headers commit
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

Don't make a race test pass by waiting for every linked process to exit. That's a behavior ImagePlug can't require from `Vix` on successful decode paths.

Plug tests can verify response shape, status, and that ImagePlug sends no replacement body after headers commit. They can't prove a real socket abort because `Plug.Adapters.Test.Conn` concatenates chunks. Add a boundary protocol test for demand and cancellation, plus at least one real HTTP client or raw socket test for incomplete or closed streamed responses.

For the first slice, focus on pre-response boundary tests over real socket tests:

- controlled late source failure that proves the old zero-time receive can miss the error
- pending linked source and non-source exit messages already in the worker mailbox
- caller `trap_exit` remains unchanged
- caller exit cancels the worker
- non-source linked exits aren't swallowed
- non-source raises and throws replay in the caller instead of becoming source errors
- source error during existing sequential materialization returns a clean error before delivery
- automatic source-format and final-alpha paths return clean pre-response errors
- failed source-backed processing doesn't write cache

Real socket tests belong with worker-owned streaming mode.

## Post-Merge Issue Triage

After this design lands on `main`, update related GitHub issues instead of closing them from this work.

- #40 needs narrower scope. The design decides that ImagePlug never caches partial streamed output, streamed cache writes commit only after complete encode success, `fail_on_cache_error: true` keeps cache write errors pre-response, and default fail-open cache mode may stream while buffering for cache. The remaining issue scope is the cache body abstraction, streamed filesystem reads and writes, byte counting, digest validation, and adapter migration.
- #49 should mention the source worker boundary as the future hook for processing concurrency, queueing, timeout, and cancellation. The first implementation slice won't add those controls.
- #10 and #47 should mention that post-commit source, decode, and encode failures become telemetry and diagnostic events. They don't become replacement HTTP responses after ImagePlug commits headers.
- #57 should stay open. The first slice still keeps response delivery outside the new boundary; worker-owned streaming may later make conn ownership easier to define.
- #9 should stay open. The design reinforces that the source wrapper counts body bytes while libvips consumes the source enumerable, not only when Req constructs the stream.
- #61 should stay open. The design changes final response materialization goals, not intermediate multi-pipeline materialization barriers.

Use issue comments unless the issue body has stale acceptance criteria. Avoid `Closes #...` wording in the PR body for these issues.

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
