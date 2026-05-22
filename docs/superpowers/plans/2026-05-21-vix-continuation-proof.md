# Vix Continuation Proof Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to build this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove whether a real un-buffered `Image.stream!/2` encoder continuation can live inside a GenServer, resume across separate calls, and clean up observable Vix helpers on halt.

**Architecture:** This is Slice 1 only. It adds one characterization test file with a test-only GenServer. It doesn't add production `SourceSession`, supervision, `PreparedStream`, cache teeing, or response routing. If cancellation helper cleanup fails, or all helper cleanup remains inconclusive, stop and use the pre-response encode fallback in the design doc. If only post-pipe encoder failure cleanup remains inconclusive, record that before deciding whether `SourceSession` is still acceptable.

**Tech Stack:** Elixir, ExUnit, GenServer, `Enumerable.reduce/3`, un-buffered `Image.stream!/2`, `Vix.TargetPipe`, `mise exec -- mix test`.

---

## Files

- Create: `test/image_plug/request/vix_stream_continuation_test.exs`
- Read: `deps/image/lib/image.ex`
- Read: `deps/vix/lib/vix/vips/image.ex`
- Read: `deps/vix/lib/vix/target_pipe.ex`
- Edit after the proof result: `docs/superpowers/designs/2026-05-21-source-session-lifecycle-boundary.md`

Don't edit production code in this plan.

## Review Constraints Folded Into This Plan

- Use un-buffered `Image.stream!/2`. In the checked-in `image` dependency, `buffer_size == 0` bypasses `buffer!/2`; non-zero `:buffer_size` wraps the Vix stream with `Stream.chunk_while/4`, so the suspended continuation may belong to the buffer wrapper instead of direct Vix streaming.
- Treat the suspended accumulator as opaque. The test helper may choose a simple accumulator shape, but the design must not depend on the accumulator being the emitted chunk.
- Use bounded `GenServer.call/3` timeouts in tests. No `:infinity`.
- Don't use hard-coded line-number test filters. Use tags or run the focused file.
- `Vix.TargetPipe.stop/1` is `GenServer.stop(pid)`. Current Vix doesn't explicitly kill or await the writer task. If a captured writer task stays alive after halt, mark the writer cleanup proof failed.
- `.not-a-real-format` fails before `Vix.TargetPipe` exists. It only proves pre-pipe validation behavior. It must not count as post-pipe encoder failure cleanup.
- Inspect private Vix process state only in this characterization test. Don't carry helper process ID discovery into production design.

## Task 1: Prove Full Stream Through A Minimal Test GenServer

**Files:**
- Create: `test/image_plug/request/vix_stream_continuation_test.exs`

- [ ] **Step 1: Write the failing test and minimal server**

Create `test/image_plug/request/vix_stream_continuation_test.exs`:

```elixir
defmodule ImagePlug.Request.VixStreamContinuationTest do
  use ExUnit.Case, async: false

  defmodule ProofServer do
    use GenServer

    @call_timeout 5_000

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def next(pid) do
      GenServer.call(pid, :next, @call_timeout)
    end

    @impl GenServer
    def init(opts) do
      Process.flag(:trap_exit, true)

      {:links, links} = Process.info(self(), :links)

      {:ok,
       %{
         initial_links: MapSet.new(links),
         image: Keyword.fetch!(opts, :image),
         suffix: Keyword.get(opts, :suffix, ".jpg"),
         write_options: Keyword.get(opts, :write_options, []),
         stream: nil,
         suspended: nil,
         exits: []
       }}
    end

    @impl GenServer
    def handle_call(:next, _from, state) do
      {reply, state} = next_chunk(state)
      {:reply, reply, state}
    end

    @impl GenServer
    def handle_info({:EXIT, pid, :shutdown}, state) do
      # Initial links are test/supervisor ownership links, not Vix helper links.
      # Their shutdown is controlled test cleanup.
      if MapSet.member?(state.initial_links, pid) do
        {:stop, :shutdown, halt_stream(state)}
      else
        {:noreply, %{state | exits: [{pid, :shutdown} | state.exits]}}
      end
    end

    def handle_info({:EXIT, pid, reason}, state) do
      {:noreply, %{state | exits: [{pid, reason} | state.exits]}}
    end

    defp next_chunk(%{stream: nil} = state) do
      stream =
        Image.stream!(
          state.image,
          Keyword.merge([suffix: state.suffix, buffer_size: 0], state.write_options)
        )

      result = reduce_for_one_chunk(stream)
      handle_reduce_result(result, %{state | stream: stream})
    end

    defp next_chunk(%{suspended: nil} = state), do: {:done, state}

    defp next_chunk(%{suspended: {acc, continuation}} = state) do
      continuation.({:cont, acc})
      |> handle_reduce_result(%{state | suspended: nil})
    end

    defp reduce_for_one_chunk(stream) do
      Enumerable.reduce(stream, {:cont, []}, fn chunk, acc ->
        {:suspend, [chunk | acc]}
      end)
    end

    defp handle_reduce_result({:suspended, [chunk | _rest] = acc, continuation}, state)
         when is_binary(chunk) do
      {{:chunk, chunk}, %{state | suspended: {acc, continuation}}}
    end

    defp handle_reduce_result({:done, _acc}, state), do: {:done, %{state | suspended: nil}}
    defp handle_reduce_result({:halted, _acc}, state), do: {:done, %{state | suspended: nil}}

    defp halt_stream(%{suspended: nil} = state), do: state

    defp halt_stream(%{suspended: {acc, continuation}} = state) do
      _result = continuation.({:halt, acc})
      %{state | suspended: nil}
    end
  end

  @tag :full_stream
  test "collects a complete encoded stream through repeated calls" do
    image = Image.open!("priv/static/images/beach.jpg")
    pid = start_supervised!({ProofServer, image: image, suffix: ".jpg"})

    {body, chunk_count} = collect_chunks_with_count(pid, [], 0)

    assert chunk_count >= 1
    assert {:ok, decoded} = Image.open(IO.iodata_to_binary(body), access: :random, fail_on: :error)
    assert Image.width(decoded) > 0
    assert Image.height(decoded) > 0
  end

  defp collect_chunks_with_count(pid, chunks, count) do
    case ProofServer.next(pid) do
      {:chunk, chunk} -> collect_chunks_with_count(pid, [chunk | chunks], count + 1)
      :done -> {Enum.reverse(chunks), count}
    end
  end
end
```

- [ ] **Step 2: Run the tagged test**

Run:

```bash
mise exec -- mix test test/image_plug/request/vix_stream_continuation_test.exs --only full_stream
```

Expected: the test compiles and passes. If it fails because the test helper doesn't match current `Image.stream!/2` or `Enumerable.reduce/3` behavior, fix only the test helper and rerun this command.

- [ ] **Step 3: Run the focused file**

Run:

```bash
mise exec -- mix test test/image_plug/request/vix_stream_continuation_test.exs
```

Expected: `1 test, 0 failures`.

## Task 2: Prove The Real Suspended State Resumes Across Calls

**Files:**
- Edit: `test/image_plug/request/vix_stream_continuation_test.exs`

- [ ] **Step 1: Add `debug_state/1` to the server**

Add this public function after `next/1`:

```elixir
def debug_state(pid) do
  GenServer.call(pid, :debug_state, @call_timeout)
end
```

Add this callback before `handle_info/2`:

```elixir
def handle_call(:debug_state, _from, state) do
  debug_state = Map.take(state, [:suspended, :exits])
  {:reply, debug_state, state}
end
```

- [ ] **Step 2: Add the failing suspension test**

Add this test before `collect_chunks_with_count/3`:

```elixir
@tag :suspension
test "stores the real suspended reducer state between calls" do
  image = Image.open!("priv/static/images/beach.jpg")
  pid = start_supervised!({ProofServer, image: image, suffix: ".jpg"})

  assert {:chunk, first_chunk} = ProofServer.next(pid)
  assert is_binary(first_chunk)

  state_after_first_chunk = ProofServer.debug_state(pid)
  # The accumulator shape is test-owned. The proof is that the real continuation
  # returned by Enumerable.reduce/3 can be stored and resumed later.
  assert {[^first_chunk | _rest], continuation} = state_after_first_chunk.suspended
  assert is_function(continuation, 1)

  case ProofServer.next(pid) do
    :done -> :ok
    {:chunk, second_chunk} -> assert is_binary(second_chunk)
  end

  state_after_resume = ProofServer.debug_state(pid)

  assert state_after_resume.suspended == nil or
           match?({_acc, continuation} when is_function(continuation, 1), state_after_resume.suspended)
end
```

- [ ] **Step 3: Run the tagged test**

Run:

```bash
mise exec -- mix test test/image_plug/request/vix_stream_continuation_test.exs --only suspension
```

Expected: the test passes. This proves a GenServer can store the real `{acc, continuation}` tuple returned by `Enumerable.reduce/3` and resume it in a later `handle_call/3`.

- [ ] **Step 4: Run the focused file**

Run:

```bash
mise exec -- mix test test/image_plug/request/vix_stream_continuation_test.exs
```

Expected: `2 tests, 0 failures`.

## Task 3: Prove Cancel Halts The Continuation And Classify Helper Cleanup

**Files:**
- Edit: `test/image_plug/request/vix_stream_continuation_test.exs`

- [ ] **Step 1: Add `cancel/1`, helper snapshots, and diagnostics**

Add these public functions after `debug_state/1`:

```elixir
def cancel(pid) do
  GenServer.call(pid, :cancel, @call_timeout)
end

def helper_snapshot(pid) do
  GenServer.call(pid, :helper_snapshot, @call_timeout)
end
```

Add `target_pipe` and `target_task` to the initial state:

```elixir
target_pipe: nil,
target_task: nil,
```

Change `next_chunk/1` for the `stream: nil` case to capture links around first enumeration:

```elixir
defp next_chunk(%{stream: nil} = state) do
  before_links = linked_processes()

  stream =
    Image.stream!(
      state.image,
      Keyword.merge([suffix: state.suffix, buffer_size: 0], state.write_options)
    )

  result = reduce_for_one_chunk(stream)

  state =
    state
    |> Map.put(:stream, stream)
    |> capture_target_pipe(before_links)

  handle_reduce_result(result, state)
end
```

Add these callbacks before `handle_info/2`:

```elixir
def handle_call(:cancel, _from, state) do
  state = halt_stream(state)
  {:reply, :ok, state}
end

def handle_call(:helper_snapshot, _from, state) do
  {:reply, helper_snapshot(state), state}
end
```

Add these private helpers after `halt_stream/1`:

```elixir
defp capture_target_pipe(state, before_links) do
  linked_processes()
  |> MapSet.difference(before_links)
  |> Enum.find(fn pid -> process_module(pid) == Vix.TargetPipe end)
  |> attach_target_pipe(state)
end

defp attach_target_pipe(nil, state), do: state

defp attach_target_pipe(pid, state) do
  %{state | target_pipe: pid, target_task: target_task(pid)}
end

defp helper_snapshot(state) do
  %{
    target_pipe: state.target_pipe,
    target_task: state.target_task,
    exits: Enum.reverse(state.exits),
    linked_processes: MapSet.to_list(linked_processes()),
    linked_process_diagnostics: linked_process_diagnostics()
  }
end

defp target_task(pid) when is_pid(pid) do
  case :sys.get_state(pid) do
    %{task_pid: task_pid} when is_pid(task_pid) -> task_pid
    _state -> nil
  end
catch
  :exit, _reason -> nil
end

defp linked_processes do
  {:links, links} = Process.info(self(), :links)
  MapSet.new(links)
end

defp process_module(pid) when is_pid(pid) do
  case :sys.get_state(pid) do
    %{__struct__: module} -> module
    _state -> nil
  end
catch
  :exit, _reason -> nil
end

defp linked_process_diagnostics do
  linked_processes()
  |> Enum.map(fn pid ->
    %{
      pid: pid,
      current_function: Process.info(pid, :current_function),
      initial_call: Process.info(pid, :initial_call),
      registered_name: Process.info(pid, :registered_name),
      state: safe_sys_state(pid)
    }
  end)
end

defp safe_sys_state(pid) do
  :sys.get_state(pid)
catch
  :exit, reason -> {:exit, reason}
end
```

- [ ] **Step 2: Add process-down helpers**

Add these helpers below `collect_chunks_with_count/3`:

```elixir
defp assert_process_down(nil), do: :not_observed

defp assert_process_down(pid) when is_pid(pid) do
  ref = Process.monitor(pid)

  receive do
    {:DOWN, ^ref, :process, ^pid, reason} -> {:down, reason}
  after
    1_000 ->
      Process.demonitor(ref, [:flush])
      {:alive, pid}
  end
end
```

- [ ] **Step 3: Add the cancel cleanup test**

Add this test before helper functions:

```elixir
@tag :cancel_cleanup
test "cancel halts the continuation and stops the target pipe" do
  image = Image.new!(4_000, 4_000, color: [120, 40, 20], bands: 3)
  pid = start_supervised!({ProofServer, image: image, suffix: ".jpg"})

  assert {:chunk, chunk} = ProofServer.next(pid)
  assert is_binary(chunk)

  snapshot = ProofServer.helper_snapshot(pid)
  assert is_pid(snapshot.target_pipe)

  :ok = ProofServer.cancel(pid)
  assert ProofServer.next(pid) == :done

  assert {:down, _reason} = assert_process_down(snapshot.target_pipe)

  case assert_process_down(snapshot.target_task) do
    {:down, _reason} -> :ok
    :not_observed -> :ok
    {:alive, writer_pid} -> flunk("writer task stayed alive after cancel: #{inspect(writer_pid)}")
  end
end
```

- [ ] **Step 4: Run the tagged test**

Run:

```bash
mise exec -- mix test test/image_plug/request/vix_stream_continuation_test.exs --only cancel_cleanup
```

Expected decision table:

| Observation | Action |
|---|---|
| target pipe observed and down, writer down or not observed | Continue to Task 4. Record writer observation precisely in Task 5. |
| target pipe not observed | Stop. The proof can't verify Vix cleanup through this helper. Record Slice 1 as inconclusive. |
| writer task observed and still alive | Stop. The current SourceSession lazy streaming design fails the writer cleanup proof. Record Slice 1 as failed for writer cleanup. |

- [ ] **Step 5: Run the focused file if the proof can continue**

Run:

```bash
mise exec -- mix test test/image_plug/request/vix_stream_continuation_test.exs
```

Expected: `3 tests, 0 failures`.

## Task 4: Characterize Validation Failure And Post-Pipe Encoder Failure

**Files:**
- Edit: `test/image_plug/request/vix_stream_continuation_test.exs`

- [ ] **Step 1: Add failure capture to `ProofServer.next/1`**

Change `handle_call(:next, ...)` from:

```elixir
def handle_call(:next, _from, state) do
  {reply, state} = next_chunk(state)
  {:reply, reply, state}
end
```

to:

```elixir
def handle_call(:next, _from, state) do
  {reply, state} = safe_next_chunk(state)
  {:reply, reply, state}
end
```

Add this helper before `next_chunk/1`:

```elixir
defp safe_next_chunk(state) do
  next_chunk(state)
rescue
  exception -> {{:error, exception}, halt_stream(state)}
catch
  kind, reason -> {{:error, {kind, reason}}, halt_stream(state)}
end
```

This only halts the continuation present in the state passed to `safe_next_chunk/1`. If a failure creates helper processes or a continuation inside `next_chunk/1` and raises before returning updated state, `safe_next_chunk/1` can't see that new state. Treat that as a characterization result, not proof of safe failure cleanup.

- [ ] **Step 2: Add the pre-pipe validation test**

Add this test before helper functions:

```elixir
@tag :pre_pipe_validation_failure
test "invalid suffix fails before a target pipe exists" do
  image = Image.new!(100, 100, color: [120, 40, 20], bands: 3)
  pid = start_supervised!({ProofServer, image: image, suffix: ".not-a-real-format"})

  assert {:error, _reason} = ProofServer.next(pid)

  snapshot = ProofServer.helper_snapshot(pid)
  assert snapshot.target_pipe == nil
  assert snapshot.target_task == nil
end
```

- [ ] **Step 3: Run the pre-pipe validation test**

Run:

```bash
mise exec -- mix test test/image_plug/request/vix_stream_continuation_test.exs --only pre_pipe_validation_failure
```

Expected: the test passes. This doesn't prove post-pipe encoder cleanup.

- [ ] **Step 4: Decide whether a stable post-pipe encoder failure fixture exists**

Inspect current dependency behavior before adding another test:

```bash
rg "validate_options|merge_image_type_options|find_save_target|operation_call" -n deps/image/lib/image/options/write.ex deps/vix/lib/vix
```

Decision table:

| Observation | Action |
|---|---|
| You find a suffix/options/image combination that passes `Image.stream!/2` validation, creates `Vix.TargetPipe`, then fails from the writer task | Add a `@tag :post_pipe_encoder_failure` test that captures `target_pipe` and `target_task`, asserts `ProofServer.next(pid)` returns `{:error, _}`, then asserts both observed helpers are down. |
| No stable post-pipe failure fixture exists through public `Image.stream!/2` options | Don't invent a brittle fixture. Record post-pipe encoder failure cleanup as inconclusive in Task 5. |

- [ ] **Step 5: Run the focused file**

Run:

```bash
mise exec -- mix test test/image_plug/request/vix_stream_continuation_test.exs
```

Expected: all tests pass only if the previous decision table didn't stop the SourceSession path. Passing pre-pipe validation alone isn't enough to mark Slice 1 fully passed.

## Task 5: Review And Record The Decision

**Files:**
- Edit: `docs/superpowers/designs/2026-05-21-source-session-lifecycle-boundary.md`

- [ ] **Step 1: Run parallel subagent reviews**

Dispatch four read-only reviewers for the proof test and design-doc update:

1. OTP lifecycle reviewer:
   - Focus: GenServer callbacks, trapped exits, `start_supervised!/1`, bounded calls, monitors, and cancellation cleanup.
   - Ask for findings ordered by severity with file and line references.
2. Vix and Enumerable reviewer:
   - Focus: `Image.stream!/2`, `buffer_size: 0`, `Enumerable.reduce/3` suspension, `Vix.TargetPipe`, writer task observation, and failure paths.
   - Ask whether the test proves the claimed dependency behavior or overstates it.
3. Test quality reviewer:
   - Focus: brittle timing, private-state inspection, tag usage, diagnostics, and whether tests support pass, partial-pass, failed, and inconclusive outcomes.
   - Ask for any simpler test shape that proves the same behavior.
4. Architecture boundary reviewer:
   - Focus: whether the result supports the next slice, whether any production assumption leaked into tests, and whether the design-doc result paragraph matches the evidence.
   - Ask whether to continue, stop, or mark a remaining risk.

Don't start Slice 2 while review feedback remains open.

- [ ] **Step 2: Apply accepted review feedback**

Apply only feedback that's technically correct for this repository. Push back in the plan notes or final summary when feedback conflicts with dependency source or the Slice 1 scope.

After edits, rerun:

```bash
mise exec -- mix test test/image_plug/request/vix_stream_continuation_test.exs
```

Expected: all tests pass for the recorded outcome, or the slice result records the failing cleanup proof.

- [ ] **Step 3: Update the design doc result section**

Add exactly one result paragraph under `## Characterization Tests First`.

Use this paragraph only if all proof dimensions pass:

```markdown
Slice 1 passed against the checked-in `image` and `vix` dependencies for un-buffered `Image.stream!/2`. Continuation resume passed. Cancellation stopped the observed `Vix.TargetPipe` and any observed writer task. Post-pipe encoder failure cleanup passed with a stable public `Image.stream!/2` failure fixture.
```

Use this paragraph if continuation resume and cancellation cleanup pass, but no stable post-pipe encoder failure fixture exists:

```markdown
Slice 1 partially passed against the checked-in `image` and `vix` dependencies for un-buffered `Image.stream!/2`. Continuation resume passed. Cancellation stopped the observed `Vix.TargetPipe`, and writer cleanup passed when the target pipe state exposed the writer task. Post-pipe encoder failure cleanup remains unproven because no stable failure fixture was found through public `Image.stream!/2` options. Treat that as an explicit remaining risk before continuing to `SourceSession`.
```

Use this paragraph if the target pipe is down but a writer task stays alive after cancel:

```markdown
Slice 1 failed against the checked-in `image` and `vix` dependencies. Halting the un-buffered `Image.stream!/2` continuation stops the observed `Vix.TargetPipe`, but an observed writer task can remain alive after cancellation. Don't build `SourceSession` as a pull-based lazy encoder unless the Vix writer cleanup design changes.
```

Use this paragraph if the target pipe doesn't show up:

```markdown
Slice 1 is inconclusive against the checked-in `image` and `vix` dependencies. The proof didn't reliably observe `Vix.TargetPipe` cleanup from a suspended un-buffered `Image.stream!/2` continuation. Don't build production helper tracking from this test shape.
```

- [ ] **Step 4: Run formatting**

Run:

```bash
mise exec -- mix format test/image_plug/request/vix_stream_continuation_test.exs
```

Expected: exit 0.

- [ ] **Step 5: Run the proof tests**

Run:

```bash
mise exec -- mix test test/image_plug/request/vix_stream_continuation_test.exs
```

Expected: all tests pass for the recorded outcome. If a test fails because it found a cleanup violation, record the failure and stop the SourceSession path.

- [ ] **Step 6: Run Vale on the design doc and this plan**

Run from the main checkout:

```bash
vale .worktrees/source-session-lifecycle/docs/superpowers/designs/2026-05-21-source-session-lifecycle-boundary.md .worktrees/source-session-lifecycle/docs/superpowers/plans/2026-05-21-vix-continuation-proof.md
```

Expected: `0 errors, 0 warnings and 0 suggestions`.

- [ ] **Step 7: Stage the proof result**

Run from the isolated checkout:

```bash
git add -f test/image_plug/request/vix_stream_continuation_test.exs docs/superpowers/designs/2026-05-21-source-session-lifecycle-boundary.md
```

Expected: `git status --short` shows the proof test and design doc staged.

## Self-Review

- Spec coverage: The plan proves suspended continuation resume, one-chunk pull, cancellation halt, target-pipe cleanup, and writer cleanup when observable. It records inconclusive or failed outcomes instead of overstating the result.
- Placeholder scan: The plan has no placeholder markers. The only branches are explicit characterization decision tables.
- Type consistency: The test helper exposes `next/1`, `debug_state/1`, `cancel/1`, and `helper_snapshot/1` only in the tasks where each becomes necessary.
