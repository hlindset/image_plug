# WrappedStream Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the ~140-line hand-rolled `ImagePipe.Source.WrappedStream` `Enumerable` with a small `Stream.transform`, and delete the connected atomics error-channel / `prefer_source_*` / facade machinery that became dead when the source-decode path went buffer/file-seekable (#142).

**Architecture:** The source body is fully drained to a binary in `Request.Processor.seekable_input/1` (`Enum.to_list`) *before* decode; libvips decodes from RAM, never from the live stream. So `WrappedStream` only needs to do three things while it is drained: count bytes and enforce `max_body_bytes`, reject non-binary chunks, and let source failures surface as a `StreamError`. Its suspend/resume bookkeeping, consumer-vs-producer failure separation, and `:atomics` side-channel exist only for a *lazy* libvips consumer that no longer exists. This plan moves source-exception **normalization to the single consumer** (`seekable_input`), reduces `WrappedStream` to a `Stream.transform`, and removes the now-dead readers (`Source.body_limit_exceeded?/1`, `Source.stream_error_reason/1`, `Processor.prefer_source_*`).

**Tech Stack:** Elixir, `Stream`/`Enumerable`, ExUnit, libvips via `Vix`/`Image`, `mise` task runner.

---

## Why this is safe: the vestige analysis

The `:atomics` channel and its readers originate in #110 ("Preserve source stream errors **across decode**"), from the era when libvips consumed the wrapped stream lazily, so a source failure surfaced *during decode/materialization* and the reason had to be recovered from a side-channel. Since #142 (seekable unification) the stream is eagerly drained in `seekable_input` (`processor.ex:183-187`):

- Marking the atomics is **always paired with a raise** (`wrapped_stream.ex:102-108`, `:188-201`). So a *successful* drain never sets them, and a *failed* drain raises `StreamError`, caught by the rescue at `processor.ex:186`, which returns `{:error, {:source, reason}}` **before decode is attempted**.
- Therefore `prefer_source_body_limit` / `prefer_source_stream_error` (`processor.ex:259-275`), which read the atomics during *materialization*, are **no-ops on both the buffer path (drain already raised/returned) and the path response (no `WrappedStream` at all)**.
- The suspend/resume continuation support and the `consumer_failure_ref` consumer-vs-producer separation only matter for an `Enumerable.reduce` driver that *suspends* or *whose consumer fun raises*. The only production driver is `Enum.to_list`, which does neither.

**Safety net (do not weaken):** the request-boundary behavior is pinned by request-level tests that go through `seekable_input`, not through the deleted units:
- `processor_test.exs:242` "deferred source stream errors remain source errors during decode" → `{:error, {:source, :stream_exception}}` for a source that raises a *raw* exception.
- `processor_test.exs:264` "oversized stream body fails closed before decode is attempted" → `{:error, {:source, :body_too_large}}`, and asserts decode is never attempted.
- Wire-level body-limit/decode-error coverage under `test/image_pipe/` (422/415/413 mapping in `Response.Sender`).

These remain green throughout. The unit tests that pin *deleted machinery* are removed with the machinery (per repo guidelines: delete the production path and its tests, don't keep tests that police removed internals).

## Approach decision (for reviewers to scrutinize)

**Chosen: normalization moves to the consumer.** `WrappedStream.new/2` returns a plain `Stream.transform` that raises `StreamError` for `:body_too_large` / `:invalid_stream_chunk` and lets a source-raised `StreamError` propagate verbatim. *Arbitrary* (non-`StreamError`) source exceptions/throws are normalized to `{:source, :stream_exception}` at the **single drain site** (`seekable_input`), whose broadened rescue is a documented host-boundary degradation (the drained value is a host-implementable `Source` adapter stream). This is preferred over keeping a guarded custom `Enumerable`, because re-adding an in-`WrappedStream` rescue would either reintroduce the `consumer_failure_ref` distinction (no simplification) or rescue-all (semantically muddier than doing it at the consumer that knows it is draining a source).

**Rejected alternative:** keep `WrappedStream` a custom `Enumerable` that self-normalizes. It preserves a couple of unit tests but keeps the bulk of the boilerplate (lawful `{:cont,:halt,:suspend}` handling) the plan is trying to delete.

## File map

- `lib/image_pipe/request/processor.ex` — **modify**: broaden `seekable_input/1`'s rescue to map any non-`StreamError` drain failure to `{:source, :stream_exception}`; delete `prefer_source_body_limit/2` + `prefer_source_stream_error/2` and **all six of their call sites** (four inline in `decode_validate_source_response` at `:65-66` and `:81-82`, two in `handle_materialization_result` at `:241-242`); simplify `handle_materialization_result/2`.
- `lib/image_pipe/source.ex` — **modify**: delete `body_limit_exceeded?/1` and `stream_error_reason/1`; drop the now-unused `WrappedStream` struct-pattern usage; keep `wrap_response/2` calling `WrappedStream.new/2`.
- `lib/image_pipe/source/wrapped_stream.ex` — **rewrite**: from a struct + `defimpl Enumerable` (~203 lines) to a module with a single `new/2` returning a `Stream.transform`.
- `test/image_pipe/source_test.exs` — **modify**: delete the unit tests that exercise removed machinery (consumer-vs-producer separation, suspend/resume continuations, on-stream exception normalization, atomics facade); keep/adjust the byte-limit, invalid-chunk, cleanup, and `StreamError`-passthrough tests; add one `seekable_input`-level normalization test if not already covered.
- `test/image_pipe/processor_test.exs` — **no behavior change**; it is the safety net (`:242`, `:264`). Confirm green at each step.

> **Line numbers match the tree at authoring time.** Edits shift later line numbers within a file during the same run — treat every `file:line` ref as a starting hint and re-grep the named symbol/string to be exact.

---

## Baseline gate (run once before Task 1, and as the green bar after every task)

- [ ] **Step 0: Confirm the relevant suites are green before any change**

Run: `mise exec -- mix test test/image_pipe/source_test.exs test/image_pipe/processor_test.exs test/image_pipe/telemetry_test.exs`
Expected: PASS (0 failures). If anything fails before you touch code, STOP and report — the baseline is not green.

---

## Task 1: Confirm the vestige is unreachable (analysis gate, no code change)

**Rationale:** Removing a guard at a boundary is a behavior change; justify it with an unreachable-from-callers analysis (repo guideline), not "looks unused".

- [ ] **Step 1: Confirm the only production consumer of the wrapped stream is the eager drain**

Run: `grep -rn "\.stream" lib/image_pipe/request/processor.ex; grep -rn "Enum.to_list\|Enumerable.reduce\|Stream\." lib/image_pipe/request/processor.ex lib/image_pipe/source.ex`
Expected: the wrapped stream is consumed only by `stream |> Enum.to_list() |> IO.iodata_to_binary()` in `seekable_input/1` (`processor.ex:184`). No production caller suspends it or passes a failing consumer fun.

> Note the one apparent second consumer that is **not** a counterexample: `open_seekable_input`/`image_open_module` receives the **already-drained buffer** (or a path), never the wrapped stream — `seekable_input` drains and short-circuits first. The `LinkedReaderImageOpen` helper in `request_safety_test.exs` is reached only after that drain, so it is not a lazy consumer of the wrapped stream. (The suspending `Enumerable.reduce` in `source_session/producer.ex` consumes the *encoder output* stream, not the source.)

- [ ] **Step 2: Confirm the atomics readers are reached only via `prefer_source_*`, which are post-decode**

Run: `grep -rn "body_limit_exceeded?\|stream_error_reason" lib/`
Expected: readers are `Source.body_limit_exceeded?/1` + `Source.stream_error_reason/1`, called only from `prefer_source_body_limit/2` + `prefer_source_stream_error/2` in `processor.ex` (`:260`, `:269`), which run inside `materialize_before_delivery` — after a successful drain (atomics unset) or never (failed drain returned early).

- [ ] **Step 3: Record the safety net**

Confirm `processor_test.exs:242` (raw source exception → `{:source, :stream_exception}`) and `processor_test.exs:264` (`{:source, :body_too_large}`, decode not attempted) exist and pass. These pin the request-boundary behavior the rewrite must preserve. No commit (analysis only).

---

## Task 2: Add the consumer-side normalization safety net (additive, behavior-preserving)

**Rationale:** Before `WrappedStream` stops normalizing arbitrary source exceptions, the single consumer must classify them. Adding generic rescue/catch arms to `seekable_input/1` is additive now (the specific `StreamError` arm still wins for `StreamError`), so all tests stay green; it becomes load-bearing in Task 5.

**Files:**
- Modify: `lib/image_pipe/request/processor.ex` (`seekable_input/1`, ~`:183-187`)

- [ ] **Step 1: Broaden the `seekable_input/1` rescue**

Replace:

```elixir
  defp seekable_input(%Source.Response{path: nil, stream: stream}) when not is_nil(stream) do
    {:ok, {:buffer, stream |> Enum.to_list() |> IO.iodata_to_binary()}}
  rescue
    exception in [Source.StreamError] -> {:error, {:source, exception.reason}}
  end
```

with:

```elixir
  # The drained value is a host-implementable Source adapter stream (a boundary we
  # don't control). A StreamError carries a classified source reason; any other
  # exception/throw/exit raised while draining the source is normalized to a safe
  # {:source, :stream_exception} (→ 422) rather than crashing the request.
  defp seekable_input(%Source.Response{path: nil, stream: stream}) when not is_nil(stream) do
    {:ok, {:buffer, stream |> Enum.to_list() |> IO.iodata_to_binary()}}
  rescue
    exception in [Source.StreamError] -> {:error, {:source, exception.reason}}
    _exception -> {:error, {:source, :stream_exception}}
  catch
    _kind, _reason -> {:error, {:source, :stream_exception}}
  end
```

- [ ] **Step 2: Add request-boundary tests pinning the new arms and arm-ordering**

These pass immediately (today `WrappedStream` normalizes; from Task 5 the new `seekable_input` arms do) and guard two things the rewrite depends on: (a) a non-binary chunk must hit the **specific** `StreamError` arm → `{:source, :invalid_stream_chunk}`, NOT the generic arm; (b) an upstream `throw` must hit the new `catch` arm → `{:source, :stream_exception}`. Add to `test/image_pipe/processor_test.exs` (next to the existing `:242` test; re-grep its helpers `plan()`/`opts()`):

```elixir
  test "non-binary source chunks remain source errors during decode" do
    response = %Response{stream: ["ok", :bad]}
    assert {:ok, response} = Source.wrap_response(response, max_body_bytes: 20)

    assert {:error, {:source, :invalid_stream_chunk}} =
             Processor.decode_validate_source_response(response, plan(), opts())
  end

  test "upstream throws during the source drain remain source errors" do
    response = %Response{stream: Stream.map([:throw], fn _ -> throw(:boom) end)}
    assert {:ok, response} = Source.wrap_response(response, max_body_bytes: 20)

    assert {:error, {:source, :stream_exception}} =
             Processor.decode_validate_source_response(response, plan(), opts())
  end
```

- [ ] **Step 3: Run the safety-net suite (incl. the wire-level 422 pins)**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs test/image_pipe/source_test.exs test/image_pipe/request_safety_test.exs test/image_pipe/telemetry_test.exs`
Expected: PASS, including the two new tests. `request_safety_test.exs` (deferred-stream-error → 422) and `telemetry_test.exs` (oversized → 422, `:body_too_large`) are part of the observable-422 safety net.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe/request/processor.ex test/image_pipe/processor_test.exs
git commit -m "Normalize source-drain failures at seekable_input (consumer boundary)"
```

---

## Task 3: Delete the dead `prefer_source_*` readers in Processor

**Rationale:** Per Task 1, all six call sites are no-ops post-#142 (whether in the decode path or the materialize path, they run only after a *successful* drain, so the atomics are unset and both functions pass their input through). Deleting them must leave every test green — that green bar *is* the proof they were dead. **There are six call sites, not two** — missing the four inline ones in `decode_validate_source_response` breaks the compile.

**Files:**
- Modify: `lib/image_pipe/request/processor.ex` (`decode_validate_source_response/3` inline calls `:65-66`/`:81-82`, `handle_materialization_result/2` `:241-242`, and the `prefer_source_*` defs `:259-275`)

- [ ] **Step 1: Remove the four inline `prefer_source_*` calls in `decode_validate_source_response`**

In the `with` chain of `decode_validate_source_response/3`, strip the two `prefer_source_*` pipe segments from each `open_seekable_input` result so they pipe straight into `wrap_decode_error()`:

```elixir
         {:ok, header_image} <-
           open_seekable_input(input, [access: :random, fail_on: :error], opts)
           |> wrap_decode_error(),
         ...
         {:ok, image} <-
           open_seekable_input(input, decode_options, opts)
           |> wrap_decode_error() do
```

(Delete the `|> prefer_source_body_limit(source_response)` and `|> prefer_source_stream_error(source_response)` lines at `:65-66` and `:81-82`. Leave everything else in the chain unchanged.)

- [ ] **Step 2: Simplify `handle_materialization_result` and delete the `prefer_source_*` defs**

Replace:

```elixir
  defp handle_materialization_result(result, source_response) do
    result
    |> prefer_source_body_limit(source_response)
    |> prefer_source_stream_error(source_response)
    |> do_handle_materialization_result()
  end
```

with:

```elixir
  defp handle_materialization_result(result, _source_response) do
    do_handle_materialization_result(result)
  end
```

Then delete the four clauses `prefer_source_body_limit/2` (both clauses) and `prefer_source_stream_error/2` (both clauses) entirely (`processor.ex:259-275`).

> Leave `handle_materialization_result/2`'s `_source_response` parameter in place (it keeps `materialize_before_delivery/3`'s signature stable; the leading underscore silences the unused warning). Re-grep `prefer_source` to confirm **zero** remaining references in `lib/` before compiling.

- [ ] **Step 3: Run the suite (no-op deletion must stay green)**

Run: `mise exec -- mix test test/image_pipe/processor_test.exs test/image_pipe/source_test.exs test/image_pipe/telemetry_test.exs test/image_pipe/request_safety_test.exs`
Expected: PASS. `processor_test.exs:264` (`:body_too_large`) and `:242` (`:stream_exception`) still pass — they resolve via the `seekable_input` rescue, never via `prefer_source_*`.

- [ ] **Step 4: Compile clean**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean (confirms nothing else referenced the removed functions; if it errors with `undefined function prefer_source_*`, a call site was missed — re-grep `prefer_source`).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/request/processor.ex
git commit -m "Delete dead prefer_source_* readers (vestige of pre-#142 lazy decode)"
```

---

## Task 4: Delete the dead `Source` facade readers and their unit tests

**Rationale:** After Task 3, `Source.body_limit_exceeded?/1` and `Source.stream_error_reason/1` have no caller. Their unit tests pin removed machinery, so they go with the code.

**Files:**
- Modify: `lib/image_pipe/source.ex` (delete `body_limit_exceeded?/1`, `stream_error_reason/1`, ~`:117-129`)
- Modify: `test/image_pipe/source_test.exs` (delete the facade tests)

- [ ] **Step 1: Confirm no remaining caller**

Run: `grep -rn "body_limit_exceeded?\|stream_error_reason" lib/`
Expected: matches only the producer in `lib/image_pipe/source/wrapped_stream.ex` (removed in Task 5) and the facade definitions in `lib/image_pipe/source.ex` being deleted here — **no callers remain** (Task 3 removed them).

- [ ] **Step 2: Delete the two facade functions**

In `lib/image_pipe/source.ex`, delete the `@spec` + both clauses of `body_limit_exceeded?/1` and `stream_error_reason/1` (`:117-129`). Leave `wrap_response/2` and the `WrappedStream` alias in place (still used by `wrap_response/2`).

- [ ] **Step 3: Delete the facade unit tests**

In `test/image_pipe/source_test.exs`, delete these whole `test` blocks (re-grep to be exact):
- `"wrap_response accepts explicit source body limit override"` (`:266-275`) — its only WrappedStream-specific assertion is `refute Source.body_limit_exceeded?(wrapped)`; the body-limit-not-exceeded happy path is covered by `"wrapped streams keep adapter cleanup..."` and the request-boundary tests. *(If you prefer to keep a passthrough assertion, keep the block but delete only the final `refute Source.body_limit_exceeded?(wrapped)` line and the `assert Enum.to_list(wrapped.stream) == [body]` already proves passthrough.)*
- `"wrap_response wrapping a stream enforces the body limit on consumption"` (`:390-396`) — replace with the version in Task 5 Step 4 that drops the `assert Source.body_limit_exceeded?(wrapped)` line and keeps the `assert_raise StreamError`.
- `"body/stream queries degrade for a path response"` (`:410-413`) — delete entirely (pure facade test).

- [ ] **Step 4: Run the source suite**

Run: `mise exec -- mix test test/image_pipe/source_test.exs`
Expected: PASS with the deleted tests gone.

- [ ] **Step 5: Compile clean + commit**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

```bash
git add lib/image_pipe/source.ex test/image_pipe/source_test.exs
git commit -m "Delete unused Source body-limit/stream-error facade and its unit tests"
```

---

## Task 5: Rewrite `WrappedStream` as a `Stream.transform`

**Rationale:** With readers and facade gone, `WrappedStream` only needs to count bytes, enforce the limit, and reject non-binary chunks while being drained. Normalization of arbitrary source exceptions now lives at `seekable_input` (Task 2). The struct, `defimpl Enumerable`, atomics, suspend/resume, and `consumer_failure_ref` all go.

**Files:**
- Rewrite: `lib/image_pipe/source/wrapped_stream.ex`
- Modify: `test/image_pipe/source_test.exs` (delete machinery tests; keep limit/invalid-chunk/cleanup/passthrough)

- [ ] **Step 1: Replace the whole module**

Replace the entire contents of `lib/image_pipe/source/wrapped_stream.ex` with:

```elixir
defmodule ImagePipe.Source.WrappedStream do
  @moduledoc false

  alias ImagePipe.Source.StreamError

  # Wraps a source body stream to enforce `max_body_bytes` and reject non-binary
  # chunks while it is drained. The sole production consumer drains it eagerly
  # (`Request.Processor.seekable_input/1`), which classifies any *other* failure
  # of the underlying source as `{:source, :stream_exception}`. This wrapper only
  # raises the two source-side `StreamError`s it is responsible for.
  @spec new(Enumerable.t(), non_neg_integer() | :infinity) :: Enumerable.t()
  def new(stream, max_body_bytes) do
    Stream.transform(stream, 0, fn chunk, size ->
      binary = validate_chunk(chunk)
      new_size = add_size(size, binary, max_body_bytes)
      {[binary], new_size}
    end)
  end

  defp validate_chunk(chunk) when is_binary(chunk), do: chunk
  defp validate_chunk(_chunk), do: raise(StreamError, reason: :invalid_stream_chunk)

  defp add_size(size, binary, :infinity), do: size + byte_size(binary)

  defp add_size(size, binary, max_body_bytes)
       when is_integer(max_body_bytes) and max_body_bytes >= 0 do
    new_size = size + byte_size(binary)

    if new_size <= max_body_bytes do
      new_size
    else
      raise StreamError, reason: :body_too_large
    end
  end
end
```

- [ ] **Step 2: Delete the machinery unit tests in `source_test.exs`**

Delete these whole `test` blocks (re-grep names; they assert removed suspend/resume + consumer-separation + on-stream normalization):
- `"wrapped streams sanitize upstream enumerable exceptions"` (`:285-291`) — normalization now happens at `seekable_input` (pinned by `processor_test.exs:242`), not on the raw stream.
- `"wrapped streams sanitize upstream throws shaped like consumer failures"` (`:303-316`) — the `consumer_failure_ref` sentinel no longer exists.
- `"wrapped streams preserve consumer exceptions"` (`:318-328`) — consumer-vs-producer separation removed; no production consumer fails.
- `"wrapped streams preserve invalid consumer return failures"` (`:330-340`) — same.
- `"wrapped stream continuations preserve consumer exceptions"` (`:342-356`) — suspend/resume continuation support removed.

- [ ] **Step 3: Keep these tests (they assert behavior the `Stream.transform` still provides)**

Confirm these remain and pass unchanged (re-grep names):
- `"wrapped streams reject non-binary chunks"` (the `:invalid_stream_chunk` test near `:247-255`) — `validate_chunk/1` still raises it.
- `"wrapped streams enforce max body bytes"` (`:258-264`) — `add_size/3` still raises `:body_too_large`.
- `"wrapped streams keep adapter cleanup in enumerable termination path"` (`:277-283`) — `Stream.transform` propagates halt to the source, running its cleanup.
- `"wrapped streams preserve safe deferred source errors"` (`:293-301`) — a source raising `StreamError(:bad_status)` propagates verbatim through `Stream.transform`.

- [ ] **Step 4: Replace the body-limit-flag test with a flag-free version**

Replace the `"wrap_response wrapping a stream enforces the body limit on consumption"` block (already edited in Task 4 Step 3) with:

```elixir
  test "wrap_response wrapping a stream enforces the body limit on consumption" do
    {:ok, wrapped} = Source.wrap_response(%Response{stream: ["abc"]}, max_body_bytes: 2)
    assert wrapped.path == nil

    assert_raise ImagePipe.Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
  end
```

- [ ] **Step 5: Run the source + processor suites**

Run: `mise exec -- mix test test/image_pipe/source_test.exs test/image_pipe/processor_test.exs test/image_pipe/telemetry_test.exs test/image_pipe/request_safety_test.exs`
Expected: PASS. `processor_test.exs:242` now exercises the Task-2 `seekable_input` normalization (the raw RuntimeError from the source propagates through the plain `Stream.transform` and is caught at the drain's generic `rescue` arm), the new "upstream throws" test exercises the `catch` arm, the "non-binary chunks" test confirms the **specific** `StreamError` arm still wins (→ `:invalid_stream_chunk`), and `:264` still raises `:body_too_large` from `add_size/3`. `request_safety_test.exs` confirms the wire-level 422.

- [ ] **Step 6: Compile clean + commit**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean (no references to the removed struct, atomics, or `defimpl`).

```bash
git add lib/image_pipe/source/wrapped_stream.ex test/image_pipe/source_test.exs
git commit -m "Reduce WrappedStream to a Stream.transform; drop dead suspend/resume + atomics"
```

---

## Final gate (after all tasks)

- [ ] **Step 1: Full Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix test` all pass.

- [ ] **Step 2: Architecture boundary test (the change touches `Request` and `Source` boundary modules)**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS — no boundary direction crossed (`Source` still owns `WrappedStream`; `Request.Processor` still consumes via the `Source.Response` it already holds).

---

## Self-review checklist (completed by author)

- **Vestige justification (Tasks 3-4):** atomics readers proven no-op post-#142 by the eager-drain analysis; deletion green bar is the proof. ✅
- **Normalization preserved (Tasks 2 & 5):** arbitrary source-exception → `{:source, :stream_exception}` moves from `WrappedStream` to `seekable_input`, pinned by `processor_test.exs:242`. ✅
- **Body-limit / invalid-chunk preserved (Task 5):** `add_size/3` and `validate_chunk/1` still raise the same `StreamError` reasons; pinned by `source_test.exs` limit/chunk tests and `processor_test.exs:264`. ✅
- **Adapter cleanup preserved (Task 5):** `Stream.transform` propagates halt; pinned by the cleanup test. ✅
- **Deleted tests only pin removed machinery:** consumer-separation, suspend/resume continuations, on-stream normalization, atomics facade. ✅
- **Boundaries:** no new cross-boundary helper; `Source` keeps `WrappedStream`. ✅
- **Placeholders:** none — every step shows exact code/commands. ✅

## Review-cycle record (completed 2026-06-04, before execution)

Three disjoint parallel reviewers ran per repo policy; the imgproxy-compat reviewer checked against real upstream `local/imgproxy-master`.

- **imgproxy/wire-compat — ACCEPT-WITH-CHANGES.** Confirmed against upstream: oversize body → **422** (`imagedata/errors.go`, enforced pre-read), unexpected/incomplete source → 422, fail-closed-before-decode preserved; the broadened `seekable_input` rescue is scoped to the drain expression only (no decode/transform inside it) and the specific `StreamError` arm preserves adapter classifications (`:bad_status`, etc.) so nothing is mis-mapped.
- **Correctness/unreachability — ACCEPT-WITH-CHANGES.** Independently verified the deadness claim (sole consumer is `Enum.to_list` in `seekable_input`; atomics never read live; the suspending reduce in `producer.ex` consumes the *encoder* stream, not the source) and the `Stream.transform` rewrite's semantics (cleanup-on-halt, `StreamError` passthrough, byte counting).
- **Test discipline — ACCEPT-WITH-CHANGES.** Confirmed each deleted test pins only removed machinery and the request-boundary safety net (`:242`/`:264`, wire-level 422) is adequate.

**Blocking findings applied:** (1) Task 3 now removes **all six** `prefer_source_*` call sites (the four inline ones in `decode_validate_source_response` were missing and would have broken the compile); (2) added request-boundary tests for `:invalid_stream_chunk` (arm-ordering) and an upstream `throw` (the new `catch` arm) in Task 2.
**Non-blocking findings applied:** Task 1 names the `LinkedReaderImageOpen` non-counterexample; Task 4 grep wording corrected; `request_safety_test.exs` added to the Task 2/3/5 runs as part of the observable-422 net.
