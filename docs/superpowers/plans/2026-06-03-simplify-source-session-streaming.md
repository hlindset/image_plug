# Simplify Source-Session Streaming Machinery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shrink the request-time streaming subsystem to the surface its real callers actually use, without changing any observable HTTP behavior.

**Architecture:** The streaming path keeps its justified two-process core (`SourceSession` GenServer owning lifecycle/cache + `Producer` owning the suspendable libvips encode continuation, so an expensive non-streamable encode can be killed promptly when the requester disconnects). This plan removes only *accreted surface that exists for tests or for misuse the architecture precludes*: (1) the production-resident blocking `Producer` client that only tests call, relocated to test support; (2) the concurrent-call `:busy` guard for a session that has exactly one sequential owner; (3) duplicated/hand-rolled `StreamError`→tag translation collapsed within each module (including the `producer_down_reason` struct-pattern tidy). Every change is behavior-preserving for the single real caller (`ImagePipe.Request.Runner`).

**Tech Stack:** Elixir, OTP (`GenServer`, `DynamicSupervisor`, bare `spawn_link`), ExUnit, libvips via `Vix`/`Image`, `mise` task runner.

---

## Why these three and not more

The initial adversarial review floated "merge Producer into the session / pull chunks in a Task." On deeper analysis that is a **regression**: the suspendable encode continuation must be driven from one consistent process (libvips streaming target has process affinity, hence the `$callers` plumbing), and the separate Producer is precisely what lets the session stay responsive to `owner`-`DOWN` and kill an in-progress AVIF/WebP encode when a client disconnects — a real DoS-resistance property for a public image proxy. So the two-process core stays. Only honest-surface cleanups remain.

**Out of scope (deliberately):** merging the two processes; touching the `owner`-monitor / `parent`-trap lifecycle; adding `WrappedStream` suspend/resume property tests (that is hardening, not simplification — track separately). The phase-based `:not_prepared` / `:invalid_phase` fallbacks are **kept** (Task 3 removes only the concurrent-call `:busy` guard).

**Considered and declined (survey completeness — do NOT do these here):**
- **Eliminate `producer_request_ref` as redundant with `pending`.** It is set/cleared in lockstep with `pending` ([source_session.ex:104, 114, 390](lib/image_pipe/request/source_session.ex)) and only guards the `{ref, result}` and `{:producer_halt_timeout, ref}` `handle_info` clauses ([:193, :197](lib/image_pipe/request/source_session.ex)). It looks foldable, but it is **load-bearing for staleness**: the `producer_request_ref: ref` guard rejects a *late* producer reply that arrives after the demand was already resolved/cleared. Drop it and a stale `{ref, result}` with `pending: nil` falls to `handle_producer_result(_result, state)` → `abort + {:stop, :normal}`, i.e. a late message could tear down a healthy session. Removing it safely needs its own state-machine analysis + tests; that is a separate change, not a behavior-preserving cleanup. Deferred.
- **Collapse the `terminate/2` ↔ in-handler double-cleanup.** Every `{:stop, …}` handler pre-calls `stop_producer` + `abort_cache_sink`, and `terminate/2`'s `cleanup_shutdown/2` ([:416-420](lib/image_pipe/request/source_session.ex)) runs them again; the second pass is a no-op only because both are idempotent. Centralizing cleanup in `terminate/2` is a real consolidation but it changes the cleanup *ordering contract* for the kill/supervisor-shutdown paths — architecture surgery, not a mechanical tidy. Deferred.
- **Merge `SourceSession.Prepared` and `Response.PreparedStream`.** They overlap on four fields but live in different Boundary namespaces (`Request` vs `Response`) and `PreparedStream` additionally carries the `next`/`cancel` closures. Merging would force a cross-boundary shared struct, violating the namespace rules. Correctly left separate.

## File map

- `lib/image_pipe/request/source_session/producer.ex` — **modify**: delete the test-only blocking client (`next/2`, `halt/2`, `receive_reply_or_down/4`) and the now-unused `@call_timeout` / `@halt_timeout`; collapse three `StreamError` rescue/catch blocks into one helper.
- `lib/image_pipe/request/source_session.ex` — **modify**: delete the `:busy` concurrent-call guard clause; tidy `producer_down_reason/1` to match `%StreamError{}` directly.
- `lib/image_pipe/source/wrapped_stream.ex` — **modify**: collapse two identical rescue/catch blocks into one helper.
- `test/support/image_pipe/test/source_session/producer_client.ex` — **create**: the blocking ref-protocol test client (module `ImagePipe.Test.SourceSession.ProducerClient`) relocated out of `lib/`, following the existing `ImagePipe.Test.*` → `test/support/image_pipe/test/` convention (e.g. `ImagePipe.Test.OrientedFrameOrigin`).
- `test/image_pipe/request/source_session/producer_test.exs` — **modify**: drive through the relocated client.
- `test/image_pipe/request/vix_stream_continuation_test.exs` — **modify**: drive through the relocated client.
- `test/image_pipe/request/source_session_test.exs` — **modify**: delete the two manufactured-concurrency `:busy` tests (`"concurrent prepare while producer demand is pending returns busy"`, `"concurrent next while producer demand is pending returns busy"`).

> **Line numbers in this plan match the tree at authoring time.** Task 2 edits shift later line numbers within `producer.ex` and `source_session.ex` during the same run — treat every `file:line` ref as a starting hint and re-grep the named symbol/string to be exact, exactly as the test-edit steps already instruct.

## Baseline gate (run once before Task 1, and as the green bar after every task)

The whole point of a behavior-preserving refactor is that the existing suite is the safety net. Establish it green first.

- [ ] **Step 0: Confirm the relevant suite is green before any change**

Run: `mise exec -- mix test test/image_pipe/request/source_session_test.exs test/image_pipe/request/source_session/producer_test.exs test/image_pipe/request/source_session_supervisor_test.exs test/image_pipe/request/vix_stream_continuation_test.exs test/image_pipe/source/`
Expected: PASS (0 failures). If anything fails before you touch code, STOP and report — the baseline is not green.

---

## Task 1: Relocate the test-only blocking `Producer` client to test support

**Rationale:** `Producer.next/2`, `Producer.halt/2`, and `receive_reply_or_down/4` ([producer.ex:56-98](lib/image_pipe/request/source_session/producer.ex)) are called only from `producer_test.exs` and `vix_stream_continuation_test.exs`. Production uses the fire-and-forget `request_next/2` / `request_halt/2` and lets `SourceSession` own the reply/monitor handling. Carrying a second blocking demand protocol in a production boundary module violates the repo guideline "Constructor/public APIs should accept the narrowest shape that real callers use." The logic is legitimate *as test scaffolding*, so it moves to `test/support` rather than being deleted. LOC roughly moves rather than vanishes; the win is that the production module's API now matches production usage.

**Files:**
- Create: `test/support/image_pipe/test/source_session/producer_client.ex`
- Modify: `lib/image_pipe/request/source_session/producer.ex` (remove `next/2`, `halt/2`, `receive_reply_or_down/4`, `@call_timeout`, `@halt_timeout`)
- Modify: `test/image_pipe/request/source_session/producer_test.exs`
- Modify: `test/image_pipe/request/vix_stream_continuation_test.exs`

- [ ] **Step 1: Create the relocated blocking client in test support**

This is a verbatim relocation of the existing prod logic, renamed. It speaks the real `request_next`/`request_halt` ref protocol and translates a producer `:DOWN` into a tagged error, exactly as the deleted prod code did — so the existing test assertions (e.g. `{:error, {:producer, {:exit, :shutdown}}}`) keep passing unchanged.

Create `test/support/image_pipe/test/source_session/producer_client.ex` (path mirrors the existing `ImagePipe.Test.*` → `test/support/image_pipe/test/` convention, e.g. `ImagePipe.Test.OrientedFrameOrigin` at `test/support/image_pipe/test/oriented_frame_origin.ex`):

```elixir
defmodule ImagePipe.Test.SourceSession.ProducerClient do
  @moduledoc """
  Blocking, synchronous client for `ImagePipe.Request.SourceSession.Producer`,
  used only by tests. Production code drives the producer through
  `ImagePipe.Request.SourceSession`, which owns the async reply/monitor handling;
  tests want a simple call/response, so that logic lives here, in test support.
  """

  alias ImagePipe.Request.SourceSession.Producer

  @call_timeout 15_000
  @halt_timeout 2_000

  @spec next(pid(), timeout()) ::
          {:ok, {:first_chunk, binary(), String.t(), [{String.t(), String.t()}], term()}}
          | {:ok, {:chunk, binary()}}
          | {:ok, :done}
          | {:error, term()}
  def next(pid, timeout \\ @call_timeout) when is_pid(pid) do
    monitor_ref = Process.monitor(pid)
    ref = Producer.request_next(pid, self())
    receive_reply_or_down(ref, monitor_ref, pid, timeout)
  end

  @spec halt(pid(), timeout()) :: :ok | {:error, term()}
  def halt(pid, timeout \\ @halt_timeout) when is_pid(pid) do
    monitor_ref = Process.monitor(pid)
    ref = Producer.request_halt(pid, self())
    receive_reply_or_down(ref, monitor_ref, pid, timeout)
  end

  defp receive_reply_or_down(ref, monitor_ref, pid, timeout) do
    receive do
      {^ref, reply} ->
        Process.demonitor(monitor_ref, [:flush])
        reply

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        receive do
          {^ref, reply} -> reply
        after
          0 -> {:error, {:producer, {:exit, reason}}}
        end
    after
      timeout ->
        Process.demonitor(monitor_ref, [:flush])

        receive do
          {^ref, _reply} -> :ok
        after
          0 -> :ok
        end

        {:error, {:producer, :timeout}}
    end
  end
end
```

- [ ] **Step 2: Facts to know (no build change, no command)**

`test/support` is on `elixirc_paths(:test)` in `mix.exs`, and `test/support/image_pipe/test/…` compiles recursively with the suite, so the module loads automatically — no mix.exs change and no separate verification command. Step 5's test run is the proof it loaded.

Boundary: this module calls the non-exported `ImagePipe.Request.SourceSession.Producer.request_next/2` / `request_halt/2`. That is permitted — test modules are outside `Boundary` enforcement, and the existing `producer_test.exs` already aliases and calls `Producer` directly with a green baseline. Final-gate Step 2 (architecture boundary test) is the backstop if this assumption is wrong.

- [ ] **Step 3: Delete the blocking client from the production Producer**

In `lib/image_pipe/request/source_session/producer.ex`:
- Remove the `@call_timeout 15_000` and `@halt_timeout 2_000` module attributes ([producer.ex:14-15](lib/image_pipe/request/source_session/producer.ex)).
- Remove `next/2` ([producer.ex:56-65](lib/image_pipe/request/source_session/producer.ex)), `halt/2` ([producer.ex:67-72](lib/image_pipe/request/source_session/producer.ex)), and `receive_reply_or_down/4` ([producer.ex:74-98](lib/image_pipe/request/source_session/producer.ex)).
- Keep `start_link/2`, `request_next/2`, `request_halt/2`, the `loop/1` and everything below it unchanged.
- Update the comment block above `request_next/2` ([producer.ex:40-41](lib/image_pipe/request/source_session/producer.ex)) — it currently says "next/2 is only a focused test helper"; replace with: `# SourceSession drives the producer with these non-blocking primitives after enforcing single-flight demand. A blocking test client lives in ImagePipe.Test.SourceSession.ProducerClient.`

- [ ] **Step 4: Re-point the two test files onto the relocated client**

In `test/image_pipe/request/source_session/producer_test.exs`:
- Add `alias ImagePipe.Test.SourceSession.ProducerClient` near the other aliases.
- Replace every `Producer.next(` with `ProducerClient.next(` and every `Producer.halt(` with `ProducerClient.halt(`. (Occurrences: lines 107, 110, 111, 120, 122, 133, 136, 147, 153 per the current file — re-grep to be exact.)
- Leave `Producer.request_*`, `start_producer/1`, and the `Producer.start_link` child spec untouched.

In `test/image_pipe/request/vix_stream_continuation_test.exs`:
- Add the same alias.
- Replace the `Producer.next(producer)` at line 339 (re-grep) with `ProducerClient.next(producer)`. The `ProofServer.next/1` calls in that file are a *different* in-file harness — DO NOT touch those.

- [ ] **Step 5: Run the affected suites**

Run: `mise exec -- mix test test/image_pipe/request/source_session/producer_test.exs test/image_pipe/request/vix_stream_continuation_test.exs`
Expected: PASS (0 failures). If `ProducerClient` fails to load, the support path didn't pick it up — check the module name/path match.

- [ ] **Step 6: Compile clean (no unused warnings from the removed attrs/functions)**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile. (Confirms nothing else in `lib/` referenced the removed functions.)

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/request/source_session/producer.ex \
        test/support/image_pipe/test/source_session/producer_client.ex \
        test/image_pipe/request/source_session/producer_test.exs \
        test/image_pipe/request/vix_stream_continuation_test.exs
git commit -m "Relocate test-only blocking Producer client to test support"
```

---

## Task 2: Collapse duplicated `StreamError`→tag translation

**Rationale:** The identical-in-spirit `rescue StreamError -> {:source, reason}` / `catch :exit {%StreamError{}} -> {:source, reason}` block appears three times in `Producer` and twice in `WrappedStream`. They already differ subtly in the generic-fallback arm (`:producer` vs `:encode` tags), which is exactly the drift hazard that argues for one source of truth per module. Consolidate *within each module* (the two modules sit in different Boundary namespaces — `Request` vs `Source` — so they must not share a private helper).

**Files:**
- Modify: `lib/image_pipe/request/source_session/producer.ex`
- Modify: `lib/image_pipe/source/wrapped_stream.ex`

- [ ] **Step 1: Add one rescue helper in `Producer` and route the three call sites through it**

In `lib/image_pipe/request/source_session/producer.ex`, add a private helper that wraps a thunk and applies the shared `StreamError` translation, taking the generic fallback as a function so the two distinct fallbacks (`{:producer, {kind, reason}}` for `prepare_first_chunk`, `{:encode, {kind, reason}, []}` for the chunk paths) are preserved exactly:

```elixir
# Single source of truth for StreamError -> tagged-error translation.
# `fallback` builds the tag for any non-StreamError throw/exit so callers keep
# their distinct generic tags (prepare uses :producer, chunk paths use :encode).
defp with_stream_translation(fallback, fun) do
  fun.()
rescue
  exception in [StreamError] -> {:error, {:source, exception.reason}}
  exception -> {:error, {:encode, exception, __STACKTRACE__}}
catch
  :exit, {%StreamError{reason: reason}, _stacktrace} -> {:error, {:source, reason}}
  :exit, %StreamError{reason: reason} -> {:error, {:source, reason}}
  kind, reason -> fallback.(kind, reason)
end
```

**Ordering is load-bearing:** the two `StreamError` `catch :exit` arms MUST precede the `kind, reason -> fallback.(...)` arm, so a `StreamError` exit is tagged `{:source, _}` before it can reach `fallback`. Reorder them and a source-stream exit silently mistags as `{:producer, _}` / `{:encode, _}`.

Then:
- `prepare_first_chunk/1`: wrap the existing `with ... else ...` body in `with_stream_translation(&prepare_fallback/2, fn -> ... end)`, where `defp prepare_fallback(:exit, reason), do: {:error, {:producer, {:exit, reason}}}` and `defp prepare_fallback(kind, reason), do: {:error, {:producer, {kind, reason}}}`. This preserves the current `:exit`-specific arm at [producer.ex:189-190](lib/image_pipe/request/source_session/producer.ex).
- `first_chunk/1` and `continue_stream/3`: wrap their bodies with `with_stream_translation(fn kind, reason -> {:error, {:encode, {kind, reason}, []}} end, fn -> ... end)`, matching the current arm at [producer.ex:201, 253](lib/image_pipe/request/source_session/producer.ex).

Keep each function's happy-path body byte-for-byte; only the surrounding `rescue/catch` moves into the helper.

- [ ] **Step 2: Run Producer + session suites**

Run: `mise exec -- mix test test/image_pipe/request/source_session/producer_test.exs test/image_pipe/request/source_session_test.exs test/image_pipe/request/source_session_supervisor_test.exs`
Expected: PASS. The existing tests `"producer returns post-first-chunk encoder errors"` (asserts `{:encode, %RuntimeError{}, stacktrace}`) and the StreamError-source cases pin every arm, so a regression in the consolidation fails here.

- [ ] **Step 3: Add one guard helper in `WrappedStream` and route both call sites through it**

In `lib/image_pipe/source/wrapped_stream.ex`, the two blocks at [wrapped_stream.ex:78-97](lib/image_pipe/source/wrapped_stream.ex) (`reduce_stream` initial) and [wrapped_stream.ex:189-207](lib/image_pipe/source/wrapped_stream.ex) (`continue_safely`) are identical except for the try body. Extract:

```elixir
# Shared mark-and-reraise guard: a StreamError marks its own reason; any other
# exception/throw is normalized to :stream_exception. The consumer-failure throw
# (tagged with consumer_failure_ref) is re-raised verbatim so a *consumer* error
# is never misattributed to the source stream.
defp with_stream_guard(wrapped, consumer_failure_ref, fun) do
  fun.()
rescue
  error in StreamError ->
    WrappedStream.mark_stream_error(wrapped, error.reason)
    reraise error, __STACKTRACE__

  _error ->
    WrappedStream.mark_stream_error(wrapped, :stream_exception)
    reraise StreamError.exception(reason: :stream_exception), __STACKTRACE__
catch
  {^consumer_failure_ref, kind, reason, stacktrace} ->
    :erlang.raise(kind, reason, stacktrace)

  _kind, _reason ->
    WrappedStream.mark_stream_error(wrapped, :stream_exception)
    raise StreamError, reason: :stream_exception
end
```

Then rewrite `reduce_stream/3` (cont clause) as:

```elixir
defp reduce_stream(%WrappedStream{stream: stream} = wrapped, {:cont, acc}, fun) do
  consumer_failure_ref = make_ref()

  with_stream_guard(wrapped, consumer_failure_ref, fn ->
    stream
    |> Enumerable.reduce({:cont, {0, acc}}, reducer(wrapped, fun, consumer_failure_ref))
    |> unwrap_result(wrapped, fun, consumer_failure_ref)
  end)
end
```

and `continue_safely/5` as:

```elixir
defp continue_safely(wrapped, continuation, command, fun, consumer_failure_ref) do
  with_stream_guard(wrapped, consumer_failure_ref, fn ->
    continuation.(command)
    |> unwrap_result(wrapped, fun, consumer_failure_ref)
  end)
end
```

- [ ] **Step 4: Run the source suite (WrappedStream is exercised through `req_stream`/`source`/`http` tests)**

Run: `mise exec -- mix test test/image_pipe/source/ test/image_pipe/request/source_session/producer_test.exs test/image_pipe/request/vix_stream_continuation_test.exs`
Expected: PASS. The body-limit/stream-error cases under `test/image_pipe/source/` cover the initial `reduce_stream` arm; the Producer suspend/continue suites drive the `continue_safely` arm. **Caveat:** the `consumer_failure_ref` re-raise arm has no direct test (a pre-existing coverage gap, not introduced here) — the refactor preserves it verbatim, including the explicit-stacktrace `:erlang.raise(kind, reason, stacktrace)`, so it is unchanged by inspection rather than pinned by a test.

- [ ] **Step 5: Tidy `producer_down_reason/1` to match `%StreamError{}` directly (folded in — same StreamError-tidy theme)**

This rides along in the same commit because it is the same "stop hand-rolling `StreamError` shapes" cleanup, in the third module. In `lib/image_pipe/request/source_session.ex`, add `alias ImagePipe.Source.StreamError` to the alias block at the top (with the others). Replace:

```elixir
defp producer_down_reason(
       {%{__struct__: ImagePipe.Source.StreamError, reason: reason}, _stacktrace}
     ) do
  {:source, reason}
end

defp producer_down_reason(%{__struct__: ImagePipe.Source.StreamError, reason: reason}) do
  {:source, reason}
end
```

with:

```elixir
defp producer_down_reason({%StreamError{reason: reason}, _stacktrace}), do: {:source, reason}
defp producer_down_reason(%StreamError{reason: reason}), do: {:source, reason}
```

Leave the `:normal` and catch-all `producer_down_reason/1` clauses below unchanged. `StreamError` is `defexception [:reason]`, so `%StreamError{reason: r}` and `%{__struct__: …, reason: r}` match identically — behavior-identical, just less hand-rolled.

- [ ] **Step 6: Run the session + source suites together (covers all three edited modules)**

Run: `mise exec -- mix test test/image_pipe/request/source_session_test.exs test/image_pipe/request/source_session_supervisor_test.exs test/image_pipe/source/`
Expected: PASS. The producer-crash / source-stream-error tests pin the `{:source, reason}` mapping that Step 5 touches.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/request/source_session/producer.ex \
        lib/image_pipe/source/wrapped_stream.ex \
        lib/image_pipe/request/source_session.ex
git commit -m "Collapse hand-rolled StreamError translation across Producer, WrappedStream, SourceSession"
```

---

## Task 3: Remove the concurrent-call `:busy` guard (misuse the architecture precludes)

**Rationale + reachability analysis (reviewers: scrutinize this):** `SourceSession` has exactly one real caller, `ImagePipe.Request.Runner`, running in the single Plug request process. That process drives the session strictly sequentially: `prepare` → (repeated `next` via the `PreparedStream.next` closure) → at most one `cancel`. The `next` closure is synchronous, so a second call is never issued while one is pending; `cancel` from the Sender only runs *after* a `next` returned (when a `chunk/2` send fails). Therefore no real caller ever issues a concurrent `prepare`/`next` to a session with a pending producer demand. The `handle_call(message, _from, %{pending: {_kind, _}})` `:busy` guard ([source_session.ex:95-98](lib/image_pipe/request/source_session.ex)) and the two tests that pin it manufacture the concurrency with a spawned helper process. Per the repo guideline "No impossible-internal-misuse tests" and "shrink unsupported API surface over preserving tidy errors for bad internal callers," both go.

**Safety note (verified by both the correctness and compatibility reviewers):** Removing the guard does NOT crash on a stray concurrent call. With the guard gone, a concurrent `:prepare` while pending falls to `handle_call(:prepare, _from, state)` ([source_session.ex:107-108](lib/image_pipe/request/source_session.ex)) → `{:protocol, {:invalid_phase, :preparing}}`; a concurrent `:next` while pending fails the `pending: nil` guard on the happy clause ([:111](lib/image_pipe/request/source_session.ex)) and falls to `handle_call(:next, _from, state)` ([:117-118](lib/image_pipe/request/source_session.ex)) → `{:protocol, :not_prepared}`. No unmatched-clause `FunctionClauseError`.

Be precise about observability: **none** of `:busy`, `:invalid_phase`, or `:not_prepared` has a mapping in `Response.Sender.handle_processing_error/3` — all three would raise and surface as a generic 500 *if they ever reached delivery*. They never do. The single sequential owner drives `prepare`→`next`→`cancel` in order, `cancel`'s own pending-clause ([:132](lib/image_pipe/request/source_session.ex)) bypasses this guard entirely, and `cancel` is only issued after a `next` returns. So this change alters neither a reachable status nor a reachable tag — it only deletes a tidier label for an unreachable state. (The absence of a catch-all `{:protocol, _}` clause in `Sender` is a pre-existing latent 500; not this plan's job, unreachable, noted only so a future reader doesn't think Task 3 created it.)

**What is the safety net for this task?** Not a negative wire test (there deliberately isn't one — testing impossible misuse is against the repo guidelines). The proof the single-owner invariant holds is the green real-lifecycle suites in Step 4 (`request_runner_test.exs` + `source_session_supervisor_test.exs`), which exercise the actual sequential `prepare`→`next`→`cancel` path end to end.

**Files:**
- Modify: `lib/image_pipe/request/source_session.ex` (delete the `:busy` guard clause)
- Modify: `test/image_pipe/request/source_session_test.exs` (delete the two `:busy` tests)

- [ ] **Step 1: Delete the two manufactured-concurrency tests**

In `test/image_pipe/request/source_session_test.exs`, delete the entire test blocks:
- `test "concurrent prepare while producer demand is pending returns busy" do ... end` (currently ~lines 705-722).
- `test "concurrent next while producer demand is pending returns busy" do ... end` (currently ~lines 724-749).

Re-grep for `:protocol, :busy` to confirm no other test references the tag after deletion.

- [ ] **Step 2: Run the session suite to confirm the tests are gone and the rest is green**

Run: `mise exec -- mix test test/image_pipe/request/source_session_test.exs`
Expected: PASS, with two fewer tests than the baseline. (The `:busy` guard is still present at this step; the remaining tests must not depend on it — confirm by the green bar.)

- [ ] **Step 3: Delete the `:busy` guard clause**

In `lib/image_pipe/request/source_session.ex`, remove:

```elixir
@impl GenServer
def handle_call(message, _from, %{pending: {_kind, _pending_from}} = state)
    when message in [:prepare, :next] do
  {:reply, {:error, {:protocol, :busy}}, state}
end
```

at [source_session.ex:94-98](lib/image_pipe/request/source_session.ex). Move the `@impl GenServer` annotation to the next `handle_call(:prepare, from, %{phase: :new} = state)` clause so the `@impl` stays attached to the first surviving clause of the group.

- [ ] **Step 4: Run the full session + supervisor + runner suites**

Run: `mise exec -- mix test test/image_pipe/request/source_session_test.exs test/image_pipe/request/source_session_supervisor_test.exs test/image_pipe/request_runner_test.exs`
Expected: PASS. The supervisor and runner tests exercise the real sequential `prepare`/`next`/`cancel` lifecycle and must be unaffected.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/request/source_session.ex test/image_pipe/request/source_session_test.exs
git commit -m "Drop concurrent-call :busy guard the single sequential caller can't trigger"
```

---

## Final gate (after all three tasks)

- [ ] **Step 1: Full Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix test` all pass.

- [ ] **Step 2: Architecture boundary test specifically (the cleanups touch `Request` and `Source` boundary modules)**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS — confirms no boundary direction was crossed (the per-module consolidation in Task 2 deliberately did NOT introduce a `Request`↔`Source` shared helper).

---

## Self-review checklist (completed by author)

- **Surface honesty (Task 1):** the relocated client is a verbatim move; existing assertions (`{:error, {:producer, {:exit, :shutdown}}}`, `{:error, {:producer, :timeout}}`) keep matching. ✅
- **Tag preservation (Task 2):** `prepare_first_chunk` keeps `:producer` generic tag; chunk paths keep `:encode`; `WrappedStream` keeps consumer-vs-producer failure separation via `consumer_failure_ref` — preserved verbatim by inspection, not pinned by a direct test (pre-existing gap, see Task 2 Step 4 caveat). ✅
- **No crash on misuse (Task 3):** removing `:busy` falls through to phase guards, not to an unmatched-clause crash. ✅
- **Boundaries:** Task 2 consolidates within each module only; Task 1 adds a test-support module outside any Boundary. ✅
- **Behavior preservation:** no HTTP status, header, chunking, cache, or error-mapping change is intended in any task; the existing wire-level suites are the proof. ✅
- **Placeholders:** none — every step shows the exact code/commands. ✅
