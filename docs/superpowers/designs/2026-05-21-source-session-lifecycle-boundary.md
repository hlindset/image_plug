# Source Session Lifecycle Boundary

## Decision

Replace the temporary source stream boundary with a request-scoped source session.

`ImagePlug.Request.SourceSession` should own every value that can still read from the source stream:

- the fetched `%ImagePlug.Source.Response{}`
- the source-backed `VipsImage`
- the `Image.stream!/2` enumerable
- the suspended encoder continuation
- linked exits from Vix reader and writer helper processes

The Plug request process should own only `Plug.Conn` and response delivery. It should receive encoded bytes, scalar metadata, cache entries, or errors. It shouldn't receive a source-backed image.

The first implementation slice should prove and use lazy encoding. Don't start with full prepare-then-stream encoding. Full encoding would prove process isolation. It wouldn't prove the lifecycle invariant that matters: source-backed lazy work can stay inside the session while the sender pulls chunks on demand.

## Current State

Commit `bc652817691a89b0a6993d8864e9b75ca1b970a5` added `ImagePlug.Request.SourceStreamBoundary`.

That boundary improves the previous request-process trap-exit workaround:

- the Plug request process no longer sets `trap_exit`
- source-backed work runs in an unlinked monitored worker
- `%ImagePlug.Source.StreamError{}` exits can become `{:error, {:source, reason}}`

This remains a workaround. It wraps source-backed work in a safer mailbox, then may return a `%ImagePlug.Transform.State{}` whose image can still be source-backed. Later response encoding can still happen outside the process that owned source stream exits.

The target design should make that impossible instead of trying to catch every late exit after the fact.

## Runtime Facts

These facts come from the checked-in dependency source.

`Image.stream!/2` returns an enumerable. It validates write options, converts the suffix/options, then delegates to `Vix.Vips.Image.write_to_stream/3`. With `:buffer_size`, it wraps that enumerable with `Stream.chunk_while/4`.

`Vix.Vips.Image.write_to_stream/3` uses `Stream.resource/3`. Its start callback creates a `Vix.TargetPipe`. Its next callback calls `Vix.TargetPipe.read/1`. Its after callback calls `Vix.TargetPipe.stop/1`.

`Vix.TargetPipe.new/3` starts a linked GenServer. That GenServer sets `trap_exit` in `init/1`, creates a target pipe, and spawns a linked task that runs the save operation. The read side returns chunks, `:eof`, or `{:error, reason}` to the process enumerating the stream.

These facts imply the right ownership boundary:

- if `SourceSession` creates and enumerates the encoder stream, `TargetPipe` links land under `SourceSession`
- if `SourceSession` traps exits from startup, helper exits arrive as messages there
- if `SourceSession` stores the suspended enumerable continuation in its own state, later `handle_call/3` callbacks resume the continuation in the same process
- if cancellation calls the continuation with `{:halt, acc}`, the `Stream.resource/3` after callback should stop `TargetPipe`

The last point is load-bearing. Test it with the real Vix implementation before wiring the full request path.

## `Image.from_req_stream/2` Spike Result

`Image.from_req_stream/2` is useful for checking whether Image can decode a sanitized `Req.Request` without ImagePlug's custom byte stream. A characterization spike showed that it can decode a normal `200` response built from adapter request options.

It doesn't preserve ImagePlug's source contract as a direct replacement:

- it returns a decoded image, not a `%ImagePlug.Source.Response{}`
- it only accepts status `200`; a `206` response with a valid image body returns the same generic loader error as `404`
- it reads only its own `:timeout` option and doesn't enforce ImagePlug's `:max_body_bytes`
- non-`200` responses collapse to `"Failed to find loader for the source"` instead of `{:source, :bad_status}`

That keeps `Image.from_req_stream/2` out of the next implementation slice. Source adapters still need a byte-stream boundary that enforces ImagePlug body limits and source error taxonomy before decode.

## Contract

ImagePlug has two response phases.

### Before Headers Commit

ImagePlug can still choose the status, headers, and body. Failures before `prepare/1` returns the first encoded chunk should continue to return clean HTTP errors.

Examples:

- parser and planner validation failures
- source resolution failures
- denied source hosts
- source failures that surface before the first encoded chunk
- output negotiation failures
- decode failures that surface before the first encoded chunk
- encode failures before the first encoded chunk
- empty output streams
- cache failures when `fail_on_cache_error: true`

The session should produce the first encoded chunk before the sender commits headers. That keeps empty output streams and first-chunk encoder failures in the pre-response phase.

### After Headers Commit

After `send_chunked/2`, ImagePlug can't replace the response with a `422`, `415`, or `500` body. Late source, decode, output, encode, and client-close failures are stream failures.

Post-commit failures should:

- abort delivery
- emit telemetry with a low-cardinality phase and normalized error
- skip cache writes for partial output
- leave the client to observe an incomplete response or decode failure

`200` means ImagePlug accepted the request and started image delivery. It doesn't prove every lazy source read and encoder write completed.

## SourceSession

Add a private request module:

```elixir
ImagePlug.Request.SourceSession
```

The process should use `GenServer`.

A supervised task with a custom protocol would be enough for a one-shot pipeline, but this lifecycle isn't one-shot after headers commit. The process must hold the encoder continuation, answer repeated demand, handle cancellation, and later tee bytes into cache. A GenServer makes those states explicit and keeps the protocol inside OTP callbacks.

Use a simple phase field at first. Don't use `:gen_statem` unless message handling starts branching by phase. A practical threshold: if more than three phases need different behavior for the same call, revisit `:gen_statem`.

### Public Internal API

The module is private to `ImagePlug.Request`, but its internal API should be narrow:

```elixir
start(request)
prepare(process)
next(process)
cancel(process)
```

`prepare/1`, `next/1`, and explicit `cancel/1` should wrap `GenServer.call/3`, catch call exits, and return tagged errors instead of exiting the caller.

That's an intentional synchronous pull model. The Plug process blocks while the session produces one chunk. That gives response delivery pull control and avoids pushing arbitrary image data into the request process mailbox. Local process call overhead should be small compared with source reads, libvips work, and socket writes.

Explicit cancellation should return only after the session has halted the enumerable continuation or marked that no continuation exists. If the request process exits without calling `cancel/1`, the session should observe that through an owner process reference and clean itself up.

Use `GenServer.start/3` only in isolated protocol tests. Production request flow should start sessions as supervised temporary children before `Runner` or `Response.Sender` uses them. `GenServer.start_link/3` is appropriate under `DynamicSupervisor`. Direct links from the Plug request process would reintroduce the lifecycle coupling this design removes.

Don't use the default 5 second `GenServer.call/3` timeout. `prepare/1` and `next/1` should use an explicit runtime timeout. Use `:infinity` only when source, transport, and request limits are already the outer cancellation boundary. `cancel/1` should use a bounded cleanup timeout. If cleanup times out, the supervisor should stop the session and discard cache buffers. After headers commit, cleanup timeout telemetry or logging is diagnostic only. It can't change the HTTP response.

Call wrapper errors should keep the response phase explicit:

- before headers commit, `:noproc`, timeout, and abnormal session exits become clean processing errors
- after headers commit, the same failures become stream failures with telemetry and aborted delivery

`Runner` and `Response.Sender` shouldn't rely on raw `GenServer.call/3` exits.

### State

The state should contain only session-owned runtime data:

```elixir
%{
  phase: :new | :preparing | :prepared | :streaming | :done | :failed | :cancelled,
  parent: pid(),
  owner: pid(),
  owner_monitor: reference(),
  request: %ImagePlug.Request.SourceSession.Request{},
  suspended: {acc, continuation} | nil,
  known_links: %{optional(pid()) => :parent | :helper},
  response_metadata: map() | nil,
  resolved_output: ImagePlug.Output.Resolved.t() | nil,
  cache_buffer: term() | nil
}
```

The `suspended` field stores the accumulator returned by `Enumerable.reduce/3` and the continuation returned with `{:suspended, acc, continuation}`. Resume with `continuation.({:cont, acc})`. Cancel with `continuation.({:halt, acc})`.

In production, `parent` is the supervisor process linked through `DynamicSupervisor`, and `owner` is the Plug request process. Owner death means request cancellation. Parent shutdown means controlled OTP shutdown, not an image-processing error. In isolated protocol tests, the same test process may start the session and act as owner. Tests should still model the two roles explicitly.

Use structs once the shape stabilizes. The first slice can keep the struct smaller:

- request input
- parent process
- owner process reference
- optional observed helper links
- current phase
- suspended continuation state
- response metadata
- resolved output

Don't store `Plug.Conn`.

Don't send `%ImagePlug.Transform.State{}` or `VipsImage` back to the caller.

Define the request input as a private struct:

```elixir
%ImagePlug.Request.SourceSession.Request{
  plan: ImagePlug.Plan.t(),
  response: ImagePlug.Plan.Response.t(),
  resolved_source: ImagePlug.Source.Resolved.t(),
  output_policy: ImagePlug.Output.Policy.t(),
  opts: keyword()
}
```

`Runner` should build `output_policy` from `Plug.Conn`, the output plan, and runtime options before starting the session. The session receives only the policy and scalar request data, not the conn.

### Process Flags

Set `Process.flag(:trap_exit, true)` in `init/1`.

Trapping exits is this process's job. It owns source-backed libvips work and encoder helpers. The Plug request process shouldn't trap exits because it has broader lifecycle concerns and may have unrelated links.

Trapped exits need a policy:

- while preparing or streaming, the direct continuation result wins when it returns a source, decode, output, or encode error
- helper exits that match the same failure after the direct result are duplicate signals and shouldn't overwrite the first error
- treat normal helper exits during done, cancellation, or controlled shutdown as cleanup
- treat `{:EXIT, parent, :shutdown}` and controlled application shutdown as shutdown, not image processing failure
- abnormal exits from unknown linked processes should fail the session while it's active

The implementation must track the supervisor parent. Track direct helper links only when Slice 1 proves a reliable, non-brittle way to observe them and production code needs that information to classify exits. The core safety property is that lazy Vix work happens inside `SourceSession` and cancellation halts the continuation. Production code doesn't need to know every helper process ID.

Keep the stronger `Vix.TargetPipe` and writer task assertions in characterization tests. If the enumerable continuation hides the target pipe, use link-set diffing around first enumeration or trace `Vix.TargetPipe.new/3` in tests. Don't make production correctness depend on link-set diffing.

Owner monitoring has a limit: a GenServer running `prepare/1` or resuming a continuation can't process the owner `:DOWN` message until the callback returns. Source adapters and request runtime options must keep blocking fetches bounded. If prompt cancellation while blocked becomes necessary, this design needs an external watchdog that can stop the session without waiting for the session mailbox.

### Prepare

`prepare/1` should do the source-backed pre-delivery work and pull exactly one encoded chunk.

The session should:

1. Fetch the source.
2. Decode and check the source.
3. Execute transforms.
4. Resolve output that needs source format or final alpha.
5. Build the `Image.stream!/2` enumerable.
6. Call `Enumerable.reduce/3` with a reducer that suspends after the first chunk.
7. Store the continuation in state.
8. Reply with a prepared stream value that contains metadata and the first chunk.

`prepare/1` has one core invariant: it must reply with either a non-empty first encoded chunk or a clean pre-response error. It must never return a prepared stream unless the encoder has already produced bytes.

Classify these as pre-response errors:

- failure while building the stream enumerable
- failure inside the first `Enumerable.reduce/3`
- immediate `{:error, reason}` from `Vix.TargetPipe.read/1`
- an empty encoder stream
- linked helper failure observed before the first chunk

### Next

`next/1` resumes the stored suspended continuation once. Calling `next/1` before a successful `prepare/1` is a caller bug, but the public wrapper should still return a tagged protocol error:

```elixir
{:error, {:protocol, :not_prepared}}
```

The reducer should suspend after one chunk, store the new `{acc, continuation}` pair, and reply:

```elixir
{:chunk, binary}
```

If the stream finishes, reply:

```elixir
:done
```

If the continuation raises or exits, translate the result into a session failure:

```elixir
{:error, {phase, reason}}
```

The caller decides whether that error is still pre-response or already post-commit. In normal response delivery, `next/1` errors after the first chunk are post-commit stream failures.

### Cancel

`cancel/1` should halt the stored suspended continuation:

```elixir
continuation.({:halt, acc})
```

That path must run the `Stream.resource/3` cleanup callback and stop `Vix.TargetPipe`.

After cancellation, the session should stop normally. The session must discard partial cache buffers. A cancelled session should ignore normal helper exits that arrive during cleanup, but still surface abnormal exits in tests so cleanup bugs are visible.

## Response PreparedStream

Add a small private response struct:

```elixir
ImagePlug.Response.PreparedStream
```

Suggested shape:

```elixir
%ImagePlug.Response.PreparedStream{
  first_chunk: binary(),
  content_type: String.t(),
  headers: [{String.t(), String.t()}],
  next: (-> {:chunk, binary()} | :done | {:error, {atom(), term()}}),
  cancel: (-> :ok | {:error, term()}),
  resolved_output: ImagePlug.Output.Resolved.t()
}
```

This is the contract between request orchestration and response delivery.

The module should use `@moduledoc false`. Elixir doesn't enforce private modules, so the boundary also depends on `ImagePlug.Response` exports and tests that use `PreparedStream` as the only lazy response handoff.

`first_chunk` must be a non-empty binary. Elixir's type system can't enforce that at compile time, so `prepare/1` and `Runner` must enforce it before constructing this struct.

`Response.Sender` shouldn't receive a transform state for source-backed streaming responses. If it receives a `PreparedStream`, it can only send bytes and ask the session for the next byte chunk.

This is the main safety property. The type shape prevents the sender from encoding a source-backed image in the wrong process.

The `headers` field must be the final checked delivery header list, including content disposition. `Response.Sender` shouldn't discover response header contract errors after `send_chunked/2`.

## Boundary Changes

Keep the compile-time dependency direction as `Request -> Response`, not `Response -> Request`.

`SourceSession` remains under `ImagePlug.Request`. `PreparedStream` belongs under `ImagePlug.Response` because `Response.Sender` consumes it. `Runner` can construct a `Response.PreparedStream` with `next` and `cancel` callbacks that call `SourceSession`. `Response.Sender` invokes those callbacks without aliasing or depending on request modules.

Update the `ImagePlug.Response` boundary exports to include `ImagePlug.Response.PreparedStream`. Keep `ImagePlug.Response` free of `ImagePlug.Request` and `ImagePlug.Source` dependencies. Add focused architecture tests for that direction.

`ImagePlug.Application` must be able to start `ImagePlug.Request.SourceSessionSupervisor`. Either add `ImagePlug.Request` to the application boundary dependencies, or place the supervisor in a boundary the application can depend on. Prefer adding the explicit application dependency and an architecture test, because the supervisor is request lifecycle infrastructure.

## Runner Flow

Keep parser validation, planner validation, source resolution, cache configuration validation, and cache lookup outside `SourceSession`.

Those steps don't consume source bytes and should fail before any source fetch.

Use this routing before cache teeing exists:

| Case | Route |
| --- | --- |
| cache hit | return the cache entry |
| no configured cache | start a supervised `SourceSession` and return `Response.PreparedStream` |
| resolved source has `cache: :skip` | start a supervised `SourceSession` and return `Response.PreparedStream` |
| configured cache miss | keep the existing pre-response full encode/cache path |
| configured cache read error with fail-open miss | keep the existing pre-response full encode/cache path |

For prepared streams:

1. Start a `SourceSession` through `SourceSessionSupervisor`.
2. Call `prepare/1`.
3. Check final delivery headers, including content disposition.
4. If `prepare/1` or header validation returns a clean error, cancel the session and return the existing processing error shape for `Response.Sender`.
5. If `prepare/1` returns a first chunk and final headers are valid, return a new delivery shape:

```elixir
{:prepared_stream, %ImagePlug.Response.PreparedStream{}, response}
```

Don't wire direct `GenServer.start/3` sessions into the request path. Direct starts are for protocol tests only.

## Response Sender Flow

For `PreparedStream`, the sender should:

1. Put already-validated response headers and content type.
2. Call `send_chunked(conn, 200)`.
3. Send `first_chunk`.
4. Loop:
   - after each successful `chunk/2`, call `prepared_stream.next.()`
   - on `{:chunk, binary}`, send the chunk
   - on `:done`, return the conn
   - on `{:error, {phase, reason}}`, emit post-commit telemetry and return a conn marked with a processing error
5. On `send_chunked/2` failure, first-chunk failure, `Plug.Conn.chunk/2` returning `{:error, :closed}` or another send error, call `prepared_stream.cancel.()`.

The sender shouldn't try to turn post-commit failures into HTTP error bodies.

After the sender attempts `send_chunked/2`, send failures are post-commit client delivery failures. The sender should cancel in an `after` cleanup path unless it has observed `:done`. Cleanup should run for early returns, exceptions, throws, call-wrapper errors, `send_chunked/2` failures, first-chunk failures, and later chunk failures.

## Supervision

After the direct `GenServer.start/3` protocol tests pass, add:

```elixir
ImagePlug.Request.SourceSessionSupervisor
```

Use a `DynamicSupervisor` under `ImagePlug.Supervisor`.

Start sessions as temporary children. Each session belongs to one request and shouldn't restart after normal completion, cancellation, or failure.

The sender should use the `PreparedStream` callbacks and their tagged error returns. If the session dies before headers commit, return a clean processing error. If it dies after headers commit, emit telemetry and abort delivery.

## Characterization Tests First

Slice 1 reached the partial-pass outcome with `vix` pinned to `https://github.com/hlindset/vix.git` at `3a30758d44526d3c914b2076bd0be201c972f2b7` and `VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS`.

Continuation resume passed. Cancellation stopped the observed `Vix.TargetPipe` and the observed writer task. A local Vix test hook also forced a writer failure after the first chunk and verified helper cleanup.

ImagePlug can't keep that forced-failure case as stable coverage. No public `Image.stream!/2` option forces the same failure after the target pipe starts.

Accept this partial pass for Slice 2 with one dependency condition: either the Vix cleanup fix lands upstream, or ImagePlug stays pinned to the fork commit. The local forced-failure result is engineering evidence, not a dependency contract that ImagePlug can assert in CI.

Before building `SourceSession`, add a focused proof test with the real `Image.stream!/2` and Vix implementation.

Use a small real image from test fixtures.

The proof server should be a minimal GenServer that:

- creates an `Image.stream!/2` enumerable
- suspends after the first chunk
- stores the returned `{acc, continuation}` state
- resumes the continuation on separate `next/1` calls
- halts the continuation on `cancel/1`

Test these cases:

### Full Stream

Collect all chunks through repeated calls and assert the result is a valid encoded image.

### Suspend And Resume

Assert that the real `{:suspended, acc, continuation}` return from `Enumerable.reduce/3` resumes across separate `handle_call/3` invocations in the same process. Don't use a synthetic closure for this proof.

### Cancel

Capture the `Vix.TargetPipe` process ID created by the stream and its writer task process ID. Assert both exit after cancellation and encode failure.

Prefer tracing `Vix.TargetPipe.new/3` in the test process and capturing its return value. If tracing proves too brittle, run the characterization test with `async: false` and use a link-set diff around the first stream enumeration to find the new `Vix.TargetPipe` process. Use `Process.list/0` filtering only as a last resort.

After capturing the target pipe process, use `:sys.get_state/1` to inspect its `task_pid` when available. This test shouldn't only assert that bytes stop flowing. It must assert that the underlying pipe process and writer task go away. If plain `Vix.TargetPipe.stop/1` leaves the writer alive, don't wire `SourceSession` into the request path until the cleanup design changes.

### Encode Failure

Force an encoder failure with invalid write options or an unsupported output suffix passed to the real stream path. Assert the server observes a failure through `next/1` without leaving `Vix.TargetPipe` or its writer task alive.

Don't depend on exact ordering between a continuation raise and trapped `{:EXIT, process_id, reason}` messages. `SourceSession` should handle both. First error wins. Treat later trapped exits as duplicate cleanup or diagnostics, and don't swallow abnormal exits from unrelated linked processes.

### If The Proof Fails

Don't build `SourceSession` as designed if the proof fails.

Use the failure mode to choose the smaller fallback:

- if the suspended continuation doesn't resume across `handle_call/3`, drop pull-based lazy encoding
- if `{:halt, acc}` doesn't stop `Vix.TargetPipe` and its writer task, don't hold suspended Vix encoder streams across response delivery
- if failure ordering can't distinguish continuation errors from trapped exits without fragile assumptions, keep encode failures before headers
- if cleanup only works through brittle process discovery, treat that discovery as test evidence and don't make it part of production correctness

The fallback is a controlled pre-response encode path:

1. fetch, decode, transform, and encode inside the process that owns source stream failures
2. finish encode before committing headers
3. return a binary, cache entry, or ordinary byte stream that no longer depends on Vix continuation state
4. keep `ReqStream` and `WrappedStream` for source body limits, source error mapping, and Req cleanup
5. simplify or remove `SourceStreamBoundary` only after the replacement path preserves those contracts

That fallback loses post-commit lazy encoding. It keeps bounded source reads, source/decode error separation, helper cleanup, and normal HTTP error mapping before headers commit.

## Error Handling

Before headers commit, map errors to the existing response behavior:

- `{:source, reason}` -> `422`
- `{:decode, reason}` -> `415`
- `{:input_limit, reason}` -> `413`
- output or transform errors -> `422`
- encode errors -> `500`
- cache fail-closed errors -> `500`

After headers commit, represent failures as phase data:

```elixir
{:source, reason}
{:decode, reason}
{:output, reason}
{:encode, reason}
{:cache, reason}
{:client_closed, reason}
```

Post-commit telemetry should include low-cardinality phase data and normalized errors:

```elixir
%{
  result: :processing_error,
  stream_phase: :source | :decode | :output | :encode | :cache | :client,
  error: ImagePlug.Telemetry.error(reason),
  status: 200,
  output_format: format
}
```

Don't include full source URLs, request paths, filenames, parser structs, transform internals, raw exceptions, or adapter internals in telemetry metadata.

Internal errors may use `{:client_closed, reason}`. Telemetry should map that phase to `stream_phase: :client` so emitted metadata stays compact and product-neutral.

## Cache

Don't build cache teeing in the proof slice.

Slice 4 is the first production streaming slice. It should make lazy response streaming safe before cache teeing exists. Misses that can use the cache can keep the existing pre-response cache path until the streaming protocol works.

That means the prepared streaming path will exercise cache-skip and no-cache requests until cache teeing lands. Tests should cover that routing explicitly so the first production slice doesn't appear to stream cacheable misses that still use pre-response cache encoding.

When code adds cache teeing:

- tee encoded chunks inside `SourceSession`
- include `first_chunk` in the cache buffer during `prepare/1`
- commit cache only after complete encode success and successful socket delivery of every returned chunk
- discard partial cache data on source, decode, output, encode, cache, or client failure
- when the buffered cache body crosses the cache size limit, drop cache buffering and keep streaming the response
- keep streamed cacheable misses with `fail_on_cache_error: true` on the pre-response full encode/cache path
- streamed tee cache writes fail open after headers commit; a cache write failure after complete client delivery should emit telemetry or logs, not turn a successful image response into a stream failure

## Relationship To SourceStreamBoundary

Remove `SourceStreamBoundary` once `SourceSession` owns encoding.

The boundary is useful only while source-backed images can escape into normal response delivery. After `PreparedStream` replaces that handoff, keeping the boundary adds another failure path without owning the real lifecycle.

Don't revert `bc652817691a89b0a6993d8864e9b75ca1b970a5` just to remove the boundary. Keep the `WrappedStream` fixes that preserve downstream consumer failures and normalize upstream stream failures. Replace the boundary with session ownership in a forward change.

## Implementation Slices

Don't build Slice 2 abstractions while Slice 1 is still uncertain.

After each slice, pause for parallel subagent review before starting the next slice. Use reviewers with disjoint focus areas, apply accepted feedback, rerun verification, and update this design or the active plan when the review changes the decision.

Default review focus areas:

- OTP lifecycle: GenServer callbacks, trapped exits, monitors, supervision, owner-vs-parent behavior, cancellation, and bounded calls.
- Vix and Enumerable mechanics: `Image.stream!/2`, `Enumerable.reduce/3` suspension, buffering, `Vix.TargetPipe`, writer task behavior, and failure paths.
- Test quality: whether tests prove the stated claim, avoid brittle timing, and keep pass, partial-pass, failed, and inconclusive outcomes honest.
- Architecture boundaries: module direction, production/test separation, request/response contracts, cache routing, and whether the slice result justifies the next slice.

### Slice 1: Vix Continuation Proof

Add the characterization tests described in this document.

This slice answers whether the first chunk and continuation model works with real `Image.stream!/2`, and whether halt cleanup stops both `Vix.TargetPipe` and its writer task.

This slice adds no production request routing. If it fails, stop and use the fallback in "If The Proof Fails" instead of continuing to `SourceSession`.

### Slice 2: SourceSession Protocol

Start this slice only after Slice 1 passes or reaches an accepted partial-pass outcome with a pinned Vix cleanup fix.

Add `SourceSession` with direct `GenServer.start/3`.

Support:

- `prepare/1`
- `next/1`
- `cancel/1`
- owner monitoring and cleanup when the request process exits
- call wrappers with explicit timeout behavior
- parent and owner tracking, plus optional observed helper tracking when reliable
- tagged protocol errors for invalid calls such as `next/1` before `prepare/1`
- source stream errors before headers
- encode errors before first chunk
- post-first-chunk failures as session errors

No cache tee. No supervisor. No public docs yet.

### Slice 3: Supervision

Add `SourceSessionSupervisor` under `ImagePlug.Application`.

Start sessions as temporary supervised children. Update `ImagePlug.Application` and Boundary declarations intentionally. Add tests for caller exit, owner death during in-flight work, session crash before headers, and session crash after headers.

### Slice 4: PreparedStream Wiring

Add `ImagePlug.Response.PreparedStream`.

Change `Runner` to start supervised sessions and return prepared streams for cache-skip and no-cache responses. Keep configured cache misses on the existing pre-response cache path. Change `Response.Sender` to deliver prepared streams through synchronous pull callbacks.

Add tests for the routing table in this design.

### Slice 5: Cache Tee

Move cache population for streamed misses into `SourceSession`.

Commit cache entries only after complete encode success and successful socket delivery of every returned chunk. Keep `fail_on_cache_error: true` cacheable misses on the pre-response cache path unless a later design explicitly changes that contract.

### Slice 6: Public Contract Docs

Document the hybrid delivery contract after the streaming path changes user-visible behavior.

Explain that post-commit failures appear as incomplete responses and telemetry, not replacement HTTP error bodies.

## Tests

Add behavior tests, not source-text tests.

Required test coverage:

- Vix continuation proof with real `Image.stream!/2`
- cancellation stops the captured `Vix.TargetPipe` and writer task
- `SourceSession.prepare/1` returns the first chunk before headers
- empty output stays a pre-response encode error
- first-chunk encode failure stays a pre-response encode error
- `SourceSession.next/1` returns one chunk per call
- `SourceSession` call wrappers map timeout, `:noproc`, and crash exits without exiting callers
- owner death cancels the session once the active callback yields
- source and request timeouts bound callbacks that don't yield
- source stream failures before first chunk return clean source errors
- source, decode, or encode failures after first chunk become stream failures
- `Response.Sender` cancels the prepared stream on any send failure or sender exception before `:done`
- `Response.Sender` never receives a source-backed transform state for prepared streams
- `Runner` routes no-cache and `cache: :skip` requests to prepared streams while configured cache misses keep the pre-response cache path before teeing
- cache entries aren't written for partial streamed responses once cache teeing exists

Race tests need explicit handshakes. Use monitors, messages, and controlled streams. Don't use sleeps to wait for source readers, target pipes, or session shutdown.

## Non-Goals

- Don't replace the source abstraction with `Image.from_req_stream/2`.
- Don't move Req transport code while changing lifecycle ownership.
- Don't add `:gen_statem` before GenServer state becomes hard to maintain.
- Don't add cache teeing to the continuation proof.
- Don't make URL option order define processing order.
- Don't expose `SourceSession` as public API.
