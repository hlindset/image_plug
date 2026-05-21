# Simplify Source Stream Decode Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove request-mailbox coupling from `ImagePlug.Source.WrappedStream` while preserving the PR #86 CI fix: deferred source stream failures return source errors instead of leaking linked process exits.

**Architecture:** Source streams stay boring: validate chunks, enforce byte limits, normalize adapter enumerable failures into `%ImagePlug.Source.StreamError{}`. Request processing owns the Vix/Image linked-process hazard through a private monitored worker boundary. No unmaterialized source-backed image may leave that boundary.

**Tech Stack:** Elixir, ExUnit, Plug tests, `Image.open/2`, Vix streaming source pipes, `mise exec -- ...`.

---

## Review Findings Applied

Four review agents challenged the first plan. The revised design applies these findings:

- Do not use `receive ... after 0` as proof of safety. It only sees exits already in the mailbox.
- Do not set `trap_exit` in the Plug request process. It can suppress unrelated linked-process failures.
- Do not wrap `Image.open/2` and materialization separately. Lazy source reads can happen between those calls.
- Do not let `%ImagePlug.Request.Processor.Decoded{}` with a source-backed image cross out of the boundary.
- Do not test deletion of `error_receiver` by asserting no internal mailbox message. That memorializes the wrong protocol.
- Do not use a fake materializer that directly raises `ImagePlug.Source.StreamError`. That leaks source vocabulary into the transform boundary.

## Final Design

Add `ImagePlug.Request.SourceStreamBoundary`, an internal module under the Request boundary. It is not exported from `ImagePlug.Request`.

`SourceStreamBoundary.run/1` starts a monitored worker. The worker sets `trap_exit: true` around the whole source-dependent function. It converts `%ImagePlug.Source.StreamError{}` raises or linked exits into `{:error, {:source, reason}}`. The caller process only monitors the worker; it never traps exits itself.

Runner wraps complete source-dependent request work in this boundary:

- Explicit output: `Processor.process_source/3` runs inside the boundary.
- Automatic source-format output: fetch, decode, source-format inspection, output resolution, transform execution, final-alpha inspection, and final state materialization all run inside the boundary.

Processor stops owning raw process flags. It still owns decode, transform, and materialization orchestration.

Source stops knowing about request mailboxes:

- Remove `WrappedStream.error_receiver`.
- Remove `Source.forward_stream_errors/2`.
- Keep `WrappedStream` only as the stream validation/body-limit wrapper for now.

Because the library is greenfield, shrink unsupported internal test hooks while touching this code:

- Keep `:image_open_module`; it is useful for decode boundary tests.
- Collapse materializer injection to `:image_materializer_module`.
- Remove `:image_materializer`.

## Files

- Create: `lib/image_plug/request/source_stream_boundary.ex`
- Modify: `lib/image_plug/request/runner.ex`
- Modify: `lib/image_plug/request/processor.ex`
- Modify: `lib/image_plug/source.ex`
- Modify: `lib/image_plug/source/wrapped_stream.ex`
- Create: `test/image_plug/request/source_stream_boundary_test.exs`
- Modify: `test/image_plug/request_safety_test.exs`
- Modify: `test/image_plug/processor_test.exs`
- Modify: `test/image_plug/source_test.exs`

## Task 1: Add Deterministic Boundary Tests

**Files:**
- Create: `test/image_plug/request/source_stream_boundary_test.exs`
- Modify: `test/image_plug/request_safety_test.exs`

- [ ] **Step 1: Add a boundary unit test for linked source exits**

Create `test/image_plug/request/source_stream_boundary_test.exs`:

```elixir
defmodule ImagePlug.Request.SourceStreamBoundaryTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Request.SourceStreamBoundary
  alias ImagePlug.Source
  alias ImagePlug.Source.Response

  defmodule DecodeWaitsForLinkedStreamExit do
    alias ImagePlug.Source

    def open(stream) do
      parent = self()

      pid =
        spawn_link(fn ->
          send(parent, :linked_reader_started)
          Enum.to_list(stream)
        end)

      ref = Process.monitor(pid)

      receive do
        :linked_reader_started -> :ok
      after
        1_000 -> raise "linked reader did not start"
      end

      receive do
        {:DOWN, ^ref, :process, ^pid,
         {%Source.StreamError{reason: :stream_exception}, _stacktrace}} ->
          :ok

        {:DOWN, ^ref, :process, ^pid, %Source.StreamError{reason: :stream_exception}} ->
          :ok
      after
        1_000 -> raise "linked reader did not exit from source stream error"
      end

      {:error, :decode_returned_after_linked_stream_exit}
    end
  end

  test "linked source stream exits return source errors without exiting the caller" do
    response = %Response{stream: Stream.map([:raise], fn _ -> raise "raw stream failure" end)}
    assert {:ok, response} = Source.wrap_response(response, max_body_bytes: 20)

    task =
      Task.async(fn ->
        SourceStreamBoundary.run(fn ->
          DecodeWaitsForLinkedStreamExit.open(response.stream)
        end)
      end)

    assert {:error, {:source, :stream_exception}} = Task.await(task)
  end
end
```

- [ ] **Step 2: Add a boundary unit test for direct source raises**

Add this test to `test/image_plug/request/source_stream_boundary_test.exs`:

```elixir
  test "direct source stream raises return source errors" do
    response = %Response{stream: Stream.map([:raise], fn _ -> raise "raw stream failure" end)}
    assert {:ok, response} = Source.wrap_response(response, max_body_bytes: 20)

    assert {:error, {:source, :stream_exception}} =
             SourceStreamBoundary.run(fn ->
               Enum.to_list(response.stream)
               {:ok, :should_not_reach}
             end)
  end
```

- [ ] **Step 3: Add a monitored Plug-level regression**

In `test/image_plug/request_safety_test.exs`, add this helper module near `StreamErrorSourceAdapter`:

```elixir
  defmodule LinkedReaderImageOpen do
    alias ImagePlug.Source

    def open(stream, _decode_options) do
      pid = spawn_link(fn -> Enum.to_list(stream) end)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, {%Source.StreamError{reason: :stream_exception}, _stacktrace}} ->
          :ok

        {:DOWN, ^ref, :process, ^pid, %Source.StreamError{reason: :stream_exception}} ->
          :ok
      after
        1_000 ->
          raise "linked reader did not exit from source stream error"
      end

      {:error, :decode_returned_after_linked_stream_exit}
    end
  end
```

Then add this test after `"deferred source stream errors return source response errors"`:

```elixir
  test "linked source stream exits return source response errors" do
    opts =
      ImagePlug.init(
        parser: ImagePlug.Parser.Imgproxy,
        sources: [path: {StreamErrorSourceAdapter, []}],
        cache: {CacheProbe, []},
        image_open_module: LinkedReaderImageOpen
      )

    task =
      Task.async(fn ->
        ImagePlug.call(conn(:get, "/_/plain/images/stream-fails.jpg"), opts)
      end)

    conn = Task.await(task)

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
    refute_received :cache_put
  end
```

- [ ] **Step 4: Run the new tests and verify they fail**

Run:

```bash
mise exec -- mix test test/image_plug/request/source_stream_boundary_test.exs test/image_plug/request_safety_test.exs
```

Expected before implementation: `test/image_plug/request/source_stream_boundary_test.exs` fails because `ImagePlug.Request.SourceStreamBoundary` does not exist. The Plug-level test may also fail because the current code relies on `WrappedStream.error_receiver` and request-process trapping, not a request-owned monitored worker boundary.

Do not continue until the failure is understood. If both tests pass, inspect why. A passing red test means the test is not proving the intended behavior.

## Task 2: Create The Request Source Stream Boundary

**Files:**
- Create: `lib/image_plug/request/source_stream_boundary.ex`
- Modify: `lib/image_plug/request/processor.ex`

- [ ] **Step 1: Add the boundary module**

Create `lib/image_plug/request/source_stream_boundary.ex`:

```elixir
defmodule ImagePlug.Request.SourceStreamBoundary do
  @moduledoc false

  alias ImagePlug.Source

  @spec run((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def run(fun) when is_function(fun, 0) do
    parent = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(parent, {ref, self(), run_with_trapped_source_streams(fun)})
      end)

    receive do
      {^ref, ^pid, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        source_exit_to_result(reason)
    end
  end

  defp run_with_trapped_source_streams(fun) do
    trap_exit? = Process.flag(:trap_exit, true)

    try do
      fun.()
      |> receive_source_stream_exit()
    after
      Process.flag(:trap_exit, trap_exit?)
    end
  rescue
    exception in [Source.StreamError] ->
      {:error, {:source, exception.reason}}
  catch
    :exit, reason ->
      source_exit_to_result(reason)
  end

  defp receive_source_stream_exit(result) do
    receive do
      {:EXIT, _pid, {%Source.StreamError{reason: reason}, _stacktrace}} ->
        {:error, {:source, reason}}

      {:EXIT, _pid, %Source.StreamError{reason: reason}} ->
        {:error, {:source, reason}}
    after
      0 -> result
    end
  end

  defp source_exit_to_result({%Source.StreamError{reason: reason}, _stacktrace}),
    do: {:error, {:source, reason}}

  defp source_exit_to_result(%Source.StreamError{reason: reason}),
    do: {:error, {:source, reason}}

  defp source_exit_to_result(:normal), do: {:error, {:source, :stream_exception}}

  defp source_exit_to_result(reason), do: {:error, reason}
end
```

Important: this module still uses a zero-time drain inside the worker, but only as a final conversion convenience. Correctness must come from the caller putting the whole lazy source lifecycle inside the worker before it returns.

- [ ] **Step 2: Remove process trapping from Processor decode**

In `lib/image_plug/request/processor.ex`, delete:

```elixir
source_response = Source.forward_stream_errors(source_response, self())
```

Replace `decode_source_response/3` with:

```elixir
  defp decode_source_response(%Source.Response{} = source_response, decode_options, opts) do
    image_open_module = Keyword.get(opts, :image_open_module, Image)
    image_open_module.open(source_response.stream, decode_options)
  rescue
    exception in [Source.StreamError] -> {:error, {:source, exception.reason}}
  catch
    :exit, {%Source.StreamError{reason: reason}, _stacktrace} -> {:error, {:source, reason}}
    :exit, %Source.StreamError{reason: reason} -> {:error, {:source, reason}}
  end
```

Then delete `with_source_stream_exit_trap/1` and `receive_source_stream_exit/1` from `Processor`.

- [ ] **Step 3: Run processor tests**

Run:

```bash
mise exec -- mix test test/image_plug/processor_test.exs
```

Expected: tests may still fail until Runner wraps the full lifecycle in Task 3. This task is only extracting low-level process handling out of Processor.

- [ ] **Step 4: Commit boundary extraction**

Run:

```bash
git add lib/image_plug/request/source_stream_boundary.ex lib/image_plug/request/processor.ex test/image_plug/request/source_stream_boundary_test.exs test/image_plug/request_safety_test.exs
git commit -m "Add source stream request boundary"
```

## Task 3: Keep The Whole Source Lifecycle Inside The Boundary

**Files:**
- Modify: `lib/image_plug/request/runner.ex`
- Modify: `lib/image_plug/request/processor.ex`

- [ ] **Step 1: Wrap explicit-output source processing**

In `lib/image_plug/request/runner.ex`, add:

```elixir
  alias ImagePlug.Request.SourceStreamBoundary
```

Change `process_source_with_output/4` to:

```elixir
  defp process_source_with_output(plan, resolved_source, opts, %Resolved{} = resolved_output) do
    case SourceStreamBoundary.run(fn -> Processor.process_source(plan, resolved_source, opts) end) do
      {:ok, final_state} ->
        {:ok, final_state, resolved_output, resolved_output.response_headers}

      {:error, reason} ->
        {:error, reason, resolved_output.response_headers}
    end
  end
```

- [ ] **Step 2: Wrap automatic source-format processing**

Change `process_source_format_automatic/4` from:

```elixir
  defp process_source_format_automatic(plan, resolved_source, opts, policy) do
    case Processor.fetch_decode_validate_source_with_source_format(plan, resolved_source, opts) do
      {:ok, %Decoded{} = decoded} ->
        resolve_source_format_automatic(decoded, plan, opts, policy)

      {:error, error} ->
        {:error, error, policy.headers}
    end
  end
```

to:

```elixir
  defp process_source_format_automatic(plan, resolved_source, opts, policy) do
    SourceStreamBoundary.run(fn ->
      with {:ok, %Decoded{} = decoded} <-
             Processor.fetch_decode_validate_source_with_source_format(plan, resolved_source, opts) do
        resolve_source_format_automatic(decoded, plan, opts, policy)
      end
    end)
    |> case do
      {:ok, final_state, resolved_output, response_headers} ->
        {:ok, final_state, resolved_output, response_headers}

      {:error, error} ->
        {:error, error, policy.headers}
    end
  end
```

This keeps fetch, decode, source-format inspection, output resolution, transform execution, alpha inspection, and materialization inside the monitored worker.

- [ ] **Step 3: Ensure final state is materialized before leaving the boundary**

In `lib/image_plug/request/processor.ex`, change `materialize_before_delivery/3` so all final states are materialized before response delivery:

```elixir
  defp materialize_before_delivery(%State{} = state, _decode_options, opts) do
    materialize_state(state, opts)
    |> handle_materialization_result()
  end
```

This is conservative. It prevents a source-backed Vips image from escaping the source stream boundary and later failing during response encoding. It may cost more memory for random-access plans, but this library is greenfield and request safety wins over preserving an optimization with unclear lifecycle guarantees.

- [ ] **Step 4: Preserve source errors from materialization without making Transform source-aware**

Add this clause before the config/materializer wrappers:

```elixir
  defp handle_materialization_result({:error, {:source, _reason}} = error), do: error
```

Keep `ImagePlug.Transform.Materializer` unchanged. It should not alias `ImagePlug.Source`.

- [ ] **Step 5: Shrink materializer test hook API**

Change `materialize_state/2` from:

```elixir
    materializer =
      Keyword.get(
        opts,
        :image_materializer,
        Keyword.get(opts, :image_materializer_module, Materializer)
      )
```

to:

```elixir
    materializer = Keyword.get(opts, :image_materializer_module, Materializer)
```

Update tests that pass `:image_materializer` to use `:image_materializer_module`.

- [ ] **Step 6: Run focused tests**

Run:

```bash
mise exec -- mix test test/image_plug/request/source_stream_boundary_test.exs test/image_plug/processor_test.exs test/image_plug/request_safety_test.exs
```

Expected: the deterministic linked-exit tests pass.

- [ ] **Step 7: Commit lifecycle boundary**

Run:

```bash
git add lib/image_plug/request/runner.ex lib/image_plug/request/processor.ex test/image_plug/processor_test.exs test/image_plug/request_safety_test.exs
git commit -m "Contain source stream lifecycle in request worker"
```

## Task 4: Remove Source-To-Request Coupling

**Files:**
- Modify: `lib/image_plug/source/wrapped_stream.ex`
- Modify: `lib/image_plug/source.ex`
- Modify: `test/image_plug/source_test.exs`

- [ ] **Step 1: Simplify `WrappedStream`**

Replace `lib/image_plug/source/wrapped_stream.ex` with the plain wrapper version:

```elixir
defmodule ImagePlug.Source.WrappedStream do
  @moduledoc false

  @enforce_keys [:stream, :max_body_bytes]
  defstruct @enforce_keys
end

defimpl Enumerable, for: ImagePlug.Source.WrappedStream do
  alias ImagePlug.Source.StreamError

  def reduce(%{stream: stream, max_body_bytes: max_body_bytes}, acc, fun) do
    reduce_stream(stream, max_body_bytes, acc, fun)
  end

  def count(_wrapped), do: {:error, __MODULE__}
  def member?(_wrapped, _value), do: {:error, __MODULE__}
  def slice(_wrapped), do: {:error, __MODULE__}

  defp reduce_stream(stream, max_body_bytes, {:cont, acc}, fun) do
    stream
    |> Enumerable.reduce({:cont, {0, acc}}, reducer(max_body_bytes, fun))
    |> unwrap_result(fun)
  rescue
    error in StreamError ->
      reraise error, __STACKTRACE__

    _error ->
      raise StreamError, reason: :stream_exception
  catch
    _kind, _reason ->
      raise StreamError, reason: :stream_exception
  end

  defp reduce_stream(_stream, _max_body_bytes, {:halt, acc}, _fun), do: {:halted, acc}

  defp reduce_stream(stream, max_body_bytes, {:suspend, acc}, fun),
    do: {:suspended, acc, &reduce_stream(stream, max_body_bytes, &1, fun)}

  defp reducer(max_body_bytes, fun) do
    fn chunk, {size, acc} ->
      with {:ok, binary} <- validate_chunk(chunk),
           {:ok, new_size} <- add_size(size, binary, max_body_bytes) do
        case fun.(binary, acc) do
          {:cont, acc} -> {:cont, {new_size, acc}}
          {:halt, acc} -> {:halt, {new_size, acc}}
          {:suspend, acc} -> {:suspend, {new_size, acc}}
        end
      else
        {:error, reason} -> raise StreamError, reason: reason
      end
    end
  end

  defp validate_chunk(chunk) when is_binary(chunk), do: {:ok, chunk}
  defp validate_chunk(_chunk), do: {:error, :invalid_stream_chunk}

  defp add_size(size, binary, :infinity), do: {:ok, size + byte_size(binary)}

  defp add_size(size, binary, max_body_bytes)
       when is_integer(max_body_bytes) and max_body_bytes >= 0 do
    new_size = size + byte_size(binary)

    if new_size <= max_body_bytes do
      {:ok, new_size}
    else
      {:error, :body_too_large}
    end
  end

  defp unwrap_result({:done, {_size, acc}}, _fun), do: {:done, acc}
  defp unwrap_result({:halted, {_size, acc}}, _fun), do: {:halted, acc}

  defp unwrap_result({:suspended, {size, acc}, continuation}, fun) do
    {:suspended, acc, &continue(continuation, size, &1, fun)}
  end

  defp continue(continuation, size, {:cont, acc}, fun) do
    continue_safely(continuation, {:cont, {size, acc}}, fun)
  end

  defp continue(continuation, size, {:halt, acc}, fun) do
    continue_safely(continuation, {:halt, {size, acc}}, fun)
  end

  defp continue(continuation, size, {:suspend, acc}, fun) do
    continue_safely(continuation, {:suspend, {size, acc}}, fun)
  end

  defp continue_safely(continuation, command, fun) do
    continuation.(command)
    |> unwrap_result(fun)
  rescue
    error in StreamError ->
      reraise error, __STACKTRACE__

    _error ->
      raise StreamError, reason: :stream_exception
  catch
    _kind, _reason ->
      raise StreamError, reason: :stream_exception
  end
end
```

- [ ] **Step 2: Remove `Source.forward_stream_errors/2`**

Delete this block from `lib/image_plug/source.ex`:

```elixir
  @spec forward_stream_errors(Response.t(), pid()) :: Response.t()
  def forward_stream_errors(
        %Response{stream: %WrappedStream{} = stream} = response,
        receiver
      )
      when is_pid(receiver) do
    %Response{response | stream: %WrappedStream{stream | error_receiver: receiver}}
  end

  def forward_stream_errors(%Response{} = response, _receiver), do: response
```

- [ ] **Step 3: Do not add source mailbox absence tests**

Rely on existing `test/image_plug/source_test.exs` coverage for direct wrapped stream behavior:

- non-binary chunks raise `:invalid_stream_chunk`
- body limit raises `:body_too_large`
- upstream exceptions raise `:stream_exception`
- upstream `%Source.StreamError{}` reasons are preserved

Do not add a `refute_received {:source_stream_error, ...}` test. That tests an implementation detail we are deleting.

- [ ] **Step 4: Run source tests**

Run:

```bash
mise exec -- mix test test/image_plug/source_test.exs
```

Expected: all source tests pass.

- [ ] **Step 5: Commit source simplification**

Run:

```bash
git add lib/image_plug/source.ex lib/image_plug/source/wrapped_stream.ex test/image_plug/source_test.exs
git commit -m "Remove source stream request coupling"
```

## Task 5: Final Verification

**Files:**
- Verify only.

- [ ] **Step 1: Format touched files**

Run:

```bash
mise exec -- mix format lib/image_plug/request/source_stream_boundary.ex lib/image_plug/request/runner.ex lib/image_plug/request/processor.ex lib/image_plug/source.ex lib/image_plug/source/wrapped_stream.ex test/image_plug/request/source_stream_boundary_test.exs test/image_plug/processor_test.exs test/image_plug/request_safety_test.exs test/image_plug/source_test.exs
```

Expected: command exits 0.

- [ ] **Step 2: Run focused tests**

Run:

```bash
mise exec -- mix test test/image_plug/source_test.exs
mise exec -- mix test test/image_plug/request/source_stream_boundary_test.exs
mise exec -- mix test test/image_plug/processor_test.exs
mise exec -- mix test test/image_plug/request_safety_test.exs
```

Expected: all focused tests pass.

- [ ] **Step 3: Run the original CI failure location**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs:309
```

Expected: test passes.

Do not treat `--repeat-until-failure` as proof. It may be useful as extra flake hunting, but the deterministic monitored tests are the proof.

- [ ] **Step 4: Run the full suite**

Run:

```bash
mise exec -- mix test
```

Expected: all tests, doctests, and properties pass.

- [ ] **Step 5: Compile with warnings as errors**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: command exits 0. Dependency warnings may print, but the project compile must succeed.

- [ ] **Step 6: Inspect the final diff**

Run:

```bash
git diff --stat 6623a4f..HEAD
git diff 6623a4f..HEAD -- lib/image_plug/request/source_stream_boundary.ex lib/image_plug/request/runner.ex lib/image_plug/request/processor.ex lib/image_plug/source.ex lib/image_plug/source/wrapped_stream.ex test/image_plug/request/source_stream_boundary_test.exs test/image_plug/processor_test.exs test/image_plug/request_safety_test.exs test/image_plug/source_test.exs
```

Expected:

- `WrappedStream` has no `error_receiver`.
- `Source` has no `forward_stream_errors/2`.
- Request process does not call `Process.flag(:trap_exit, true)`.
- Source stream lifecycle is contained by `ImagePlug.Request.SourceStreamBoundary`.
- No unmaterialized source-backed final state leaves the boundary.
- No tests use sleeps.
- No imgproxy encrypted URL behavior changed.

- [ ] **Step 7: Push the branch**

Run:

```bash
git push
```

Expected: `fix-source-stream-exit-race` updates on `origin`.

## Risks

- Always materializing final states before response delivery may increase memory use for some random-access plans. This is intentional for this branch unless profiling proves a safer narrower boundary.
- If Vix can keep a linked source reader alive even after `copy_memory/1`, that is a deeper lifecycle problem. Stop and redesign rather than reintroducing source-to-request mailbox messages.
- `Source.wrap_response/2` remains callable in tests for now because existing source tests use it. A later cleanup can hide it behind `Source.fetch/3`.

## Self-Review

Spec coverage:

- Removes source-to-request mailbox coupling: Task 4.
- Avoids request-process `trap_exit`: Tasks 2 and 3.
- Covers lazy lifecycle gap: Task 3.
- Keeps source validation and body limits: Task 4.
- Keeps request source-error conversion: Tasks 1-3.
- Avoids imgproxy encrypted URL behavior: no imgproxy files are touched.
- Uses focused tests and no sleeps: Tasks 1 and 5.
- Uses `mise exec -- ...`: every command does.

Placeholder scan:

- No TBD placeholders.
- Every code-changing step includes concrete code.

Type consistency:

- Source stream exceptions remain `%ImagePlug.Source.StreamError{reason: reason}`.
- Request-facing source errors remain `{:error, {:source, reason}}`.
- Boundary results remain `{:ok, value} | {:error, reason}`.
