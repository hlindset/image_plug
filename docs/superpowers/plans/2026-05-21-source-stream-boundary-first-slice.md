# Source Stream Boundary First Slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to work this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the request-process source stream exit trap with a private request worker boundary that converts source stream failures to `{:error, {:source, reason}}` before response delivery.

**Architecture:** Keep Source as the stream validation and body-limit owner. Put the Vix linked-process hazard inside `ImagePlug.Request.SourceStreamBoundary`, an unlinked monitored worker owned by Request. Keep response delivery, cache write timing, Req transport, and final materialization behavior unchanged in this first slice.

**Tech Stack:** Elixir, ExUnit, Plug, `Image.open/2`, Vix stream-backed input, `mise exec -- ...`.

---

## Current Constraints

The branch already has a temporary race mitigation:

- `ImagePlug.Request.Processor.decode_source_response/3` calls `Source.forward_stream_errors/2`.
- `Processor` sets `Process.flag(:trap_exit, true)` in the Plug request process.
- `Processor` does a zero-time mailbox receive for `{:source_stream_error, ...}` and `{:EXIT, ...}`.
- `ImagePlug.Source.WrappedStream` has `error_receiver` and can send request-process messages.

This first slice removes that coupling. It doesn't add worker-owned response streaming, cache teeing, or a Req middleware refactor.

## Files

- Create: `lib/image_plug/request/source_stream_boundary.ex`
- Change: `lib/image_plug/request/runner.ex`
- Change: `lib/image_plug/request/processor.ex`
- Change: `lib/image_plug/source.ex`
- Change: `lib/image_plug/source/wrapped_stream.ex`
- Create: `test/image_plug/request/source_stream_boundary_test.exs`
- Change: `test/image_plug/request_safety_test.exs`
- Change: `test/image_plug/processor_test.exs`
- Change: `test/image_plug/source_test.exs`

## Task 1: Write Boundary Regression Tests

**Files:**
- Create: `test/image_plug/request/source_stream_boundary_test.exs`
- Change: `test/image_plug/request_safety_test.exs`

- [ ] **Step 1: Add unit tests for the private boundary**

Create `test/image_plug/request/source_stream_boundary_test.exs`:

```elixir
defmodule ImagePlug.Request.SourceStreamBoundaryTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Request.SourceStreamBoundary
  alias ImagePlug.Source
  alias ImagePlug.Source.Response

  defmodule LinkedReaderImageOpen do
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

  test "direct source stream errors return source errors" do
    response = %Response{stream: Stream.map([:raise], fn _ -> raise "raw stream failure" end)}
    assert {:ok, response} = Source.wrap_response(response, max_body_bytes: 20)

    assert {:error, {:source, :stream_exception}} =
             SourceStreamBoundary.run(fn ->
               Enum.to_list(response.stream)
               {:ok, :should_not_reach}
             end)
  end

  test "linked source stream exits return source errors without exiting the caller" do
    response = %Response{stream: Stream.map([:raise], fn _ -> raise "raw stream failure" end)}
    assert {:ok, response} = Source.wrap_response(response, max_body_bytes: 20)

    assert {:error, {:source, :stream_exception}} =
             SourceStreamBoundary.run(fn ->
               LinkedReaderImageOpen.open(response.stream)
             end)
  end

  test "caller trap_exit flag is preserved" do
    previous = Process.flag(:trap_exit, true)

    try do
      assert {:ok, :done} = SourceStreamBoundary.run(fn -> {:ok, :done} end)
      assert Process.flag(:trap_exit, true)
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "non-source linked exits are not converted to source errors" do
    assert catch_exit(
             SourceStreamBoundary.run(fn ->
               pid = spawn_link(fn -> exit(:non_source_failure) end)
               ref = Process.monitor(pid)

               receive do
                 {:DOWN, ^ref, :process, ^pid, :non_source_failure} -> :ok
               after
                 1_000 -> raise "linked process did not exit"
               end

               {:ok, :should_not_return}
             end)
           ) == :non_source_failure
  end
end
```

- [ ] **Step 2: Add a Plug-level linked-exit regression**

In `test/image_plug/request_safety_test.exs`, add this helper module near `StreamErrorSourceAdapter`:

```elixir
  defmodule LinkedReaderImageOpen do
    alias ImagePlug.Source

    def open(stream, _decode_options) do
      pid = spawn_link(fn -> Enum.to_list(stream) end)
      ref = Process.monitor(pid)

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
```

Add this test after `"deferred source stream errors return source response errors"`:

```elixir
  test "linked source stream exits return source response errors" do
    opts =
      ImagePlug.init(
        parser: ImagePlug.Parser.Imgproxy,
        sources: [path: {StreamErrorSourceAdapter, []}],
        cache: {CacheProbe, []},
        image_open_module: LinkedReaderImageOpen
      )

    conn = ImagePlug.call(conn(:get, "/_/plain/images/stream-fails.jpg"), opts)

    assert conn.status == 422
    assert conn.resp_body == "invalid image source"
    refute_received :cache_put
  end
```

- [ ] **Step 3: Verify red**

Run:

```bash
mise exec -- mix test test/image_plug/request/source_stream_boundary_test.exs test/image_plug/request_safety_test.exs
```

Expected before implementation: `test/image_plug/request/source_stream_boundary_test.exs` fails because `ImagePlug.Request.SourceStreamBoundary` doesn't exist. If the new tests pass before production code changes, stop and inspect the test setup.

## Task 2: Add The Request Source Stream Boundary

**Files:**
- Create: `lib/image_plug/request/source_stream_boundary.ex`

- [ ] **Step 1: Create the boundary module**

Create `lib/image_plug/request/source_stream_boundary.ex`:

```elixir
defmodule ImagePlug.Request.SourceStreamBoundary do
  @moduledoc false

  alias ImagePlug.Source

  @type result :: {:ok, term()} | {:error, term()}

  @spec run((-> result())) :: result()
  def run(fun) when is_function(fun, 0) do
    caller = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(caller, {ref, self(), run_worker(fun)})
      end)

    receive do
      {^ref, ^pid, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        exit(reason)
    end
  end

  defp run_worker(fun) do
    trap_exit? = Process.flag(:trap_exit, true)

    try do
      fun.()
      |> receive_linked_exit()
    after
      Process.flag(:trap_exit, trap_exit?)
    end
  rescue
    exception in [Source.StreamError] ->
      {:error, {:source, exception.reason}}
  catch
    :exit, reason ->
      handle_exit(reason)
  end

  defp receive_linked_exit(result) do
    receive do
      {:EXIT, _pid, {%Source.StreamError{reason: reason}, _stacktrace}} ->
        {:error, {:source, reason}}

      {:EXIT, _pid, %Source.StreamError{reason: reason}} ->
        {:error, {:source, reason}}

      {:EXIT, _pid, :normal} ->
        receive_linked_exit(result)

      {:EXIT, _pid, reason} ->
        exit(reason)
    after
      0 -> result
    end
  end

  defp handle_exit({%Source.StreamError{reason: reason}, _stacktrace}),
    do: {:error, {:source, reason}}

  defp handle_exit(%Source.StreamError{reason: reason}),
    do: {:error, {:source, reason}}

  defp handle_exit(reason), do: exit(reason)
end
```

This module still drains the worker mailbox with `after 0`, but correctness comes from the worker boundary, not from a request-process mailbox check. The Plug request process doesn't trap exits.

- [ ] **Step 2: Run boundary tests**

Run:

```bash
mise exec -- mix test test/image_plug/request/source_stream_boundary_test.exs
```

Expected: boundary unit tests pass.

- [ ] **Step 3: Commit the boundary module and tests**

Run:

```bash
mise exec -- git add lib/image_plug/request/source_stream_boundary.ex test/image_plug/request/source_stream_boundary_test.exs test/image_plug/request_safety_test.exs
mise exec -- git commit -m "Add source stream request boundary"
```

## Task 3: Move Request Processing Onto The Boundary

**Files:**
- Change: `lib/image_plug/request/runner.ex`
- Change: `lib/image_plug/request/processor.ex`
- Change: `test/image_plug/processor_test.exs`

- [ ] **Step 1: Stop trapping source exits in `Processor`**

In `lib/image_plug/request/processor.ex`, delete this line from `decode_source_response/3`:

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

Delete `with_source_stream_exit_trap/1` and `receive_source_stream_exit/1` from `Processor`.

- [ ] **Step 2: Wrap explicit-output processing in `Runner`**

In `lib/image_plug/request/runner.ex`, add:

```elixir
  alias ImagePlug.Request.SourceStreamBoundary
```

Replace `process_source_with_output/4` with:

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

- [ ] **Step 3: Keep automatic source-format work inside the boundary**

Replace `process_source_format_automatic/4` with:

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

      {:error, error, response_headers} ->
        {:error, error, response_headers}

      {:error, error} ->
        {:error, error, policy.headers}
    end
  end
```

This prevents `%ImagePlug.Request.Processor.Decoded{}` from leaving the worker in the automatic source-format paths.

- [ ] **Step 4: Keep current final materialization behavior**

Don't change `materialize_before_delivery/3` in this slice. It should stay:

```elixir
  defp materialize_before_delivery(%State{} = state, decode_options, opts) do
    case Keyword.fetch!(decode_options, :access) do
      :sequential -> materialize_state(state, opts) |> handle_materialization_result()
      :random -> {:ok, state}
    end
  end
```

The hybrid design rejected unconditional final materialization for this first slice. Leave worker-owned response streaming and stricter late-failure semantics for later work.

- [ ] **Step 5: Keep the materializer test hook stable**

Don't remove `:image_materializer` in this slice. Existing tests and the CI-fix branch already use it. Shrinking that unsupported test hook can happen in a separate cleanup after the race fix lands.

- [ ] **Step 6: Run focused request tests**

Run:

```bash
mise exec -- mix test test/image_plug/request/source_stream_boundary_test.exs test/image_plug/request_safety_test.exs test/image_plug/processor_test.exs
```

Expected: the new boundary tests and existing processor tests pass.

- [ ] **Step 7: Commit request boundary integration**

Run:

```bash
mise exec -- git add lib/image_plug/request/runner.ex lib/image_plug/request/processor.ex test/image_plug/request_safety_test.exs test/image_plug/processor_test.exs
mise exec -- git commit -m "Run source processing in request boundary"
```

## Task 4: Remove Source-To-Request Coupling

**Files:**
- Change: `lib/image_plug/source.ex`
- Change: `lib/image_plug/source/wrapped_stream.ex`
- Change: `test/image_plug/source_test.exs`

- [ ] **Step 1: Simplify `WrappedStream`**

Replace `lib/image_plug/source/wrapped_stream.ex` with:

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

- [ ] **Step 3: Update source tests only if needed**

Keep existing source stream tests for:

- body byte limits
- invalid chunks
- upstream enumerable exception normalization
- preserved upstream `%ImagePlug.Source.StreamError{}` reasons
- halt and suspend behavior

Don't add a `refute_received {:source_stream_error, ...}` test. That would test the removed private protocol.

- [ ] **Step 4: Run source tests**

Run:

```bash
mise exec -- mix test test/image_plug/source_test.exs
```

Expected: source tests pass.

- [ ] **Step 5: Commit source simplification**

Run:

```bash
mise exec -- git add lib/image_plug/source.ex lib/image_plug/source/wrapped_stream.ex test/image_plug/source_test.exs
mise exec -- git commit -m "Remove source stream request coupling"
```

## Task 5: Final Verification

**Files:**
- Verify only.

- [ ] **Step 1: Format touched files**

Run:

```bash
mise exec -- mix format lib/image_plug/request/source_stream_boundary.ex lib/image_plug/request/runner.ex lib/image_plug/request/processor.ex lib/image_plug/source.ex lib/image_plug/source/wrapped_stream.ex test/image_plug/request/source_stream_boundary_test.exs test/image_plug/request_safety_test.exs test/image_plug/processor_test.exs test/image_plug/source_test.exs
```

Expected: command exits 0.

- [ ] **Step 2: Run focused tests**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs
mise exec -- mix test test/image_plug/processor_test.exs
mise exec -- mix test test/image_plug/source_test.exs
mise exec -- mix test test/image_plug/request/source_stream_boundary_test.exs
```

Expected: all focused tests pass.

- [ ] **Step 3: Run the original CI failure location**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs:309
```

Expected: the source stream error regression passes.

- [ ] **Step 4: Run the full suite**

Run:

```bash
mise exec -- mix test
```

Expected: all tests pass.

- [ ] **Step 5: Compile with warnings as errors**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: command exits 0.

- [ ] **Step 6: Inspect the final diff**

Run:

```bash
mise exec -- git diff --stat origin/fix-source-stream-exit-race..HEAD
mise exec -- git diff origin/fix-source-stream-exit-race..HEAD -- lib/image_plug/request/source_stream_boundary.ex lib/image_plug/request/runner.ex lib/image_plug/request/processor.ex lib/image_plug/source.ex lib/image_plug/source/wrapped_stream.ex test/image_plug/request/source_stream_boundary_test.exs test/image_plug/request_safety_test.exs test/image_plug/processor_test.exs test/image_plug/source_test.exs
```

Expected:

- `WrappedStream` has no `error_receiver`.
- `Source` has no `forward_stream_errors/2`.
- The Plug request process doesn't set `trap_exit`.
- `ImagePlug.Request.SourceStreamBoundary` contains source stream linked exits.
- Automatic source-format paths don't return `%ImagePlug.Request.Processor.Decoded{}` across the worker boundary.
- Final materialization behavior matches the behavior before this first slice.
- No tests use `Process.sleep/1`.
- No imgproxy encrypted URL behavior changed.

- [ ] **Step 7: Push the branch after verification**

Run:

```bash
mise exec -- git push
```

Expected: `origin/fix-source-stream-exit-race` updates.

## Risks

- The worker boundary only covers pre-response source processing in this slice. It doesn't provide deterministic HTTP errors for late failures after response headers commit.
- Random-access paths keep their current materialization behavior. Don't add unconditional `copy_memory/1` in this slice.
- The boundary uses one worker process per cache miss or uncached source path. That process cost is acceptable for this safety fix and gives a later hook for concurrency and timeout controls.
- If a new test proves a source-backed image can still fail after leaving the first-slice boundary, stop and decide whether that failure belongs in this PR or in the later worker-owned streaming slice.

## Self-Review

Spec coverage:

- Fixes the source stream exit race without request-process `trap_exit`: Tasks 1-3.
- Removes source-to-request mailbox coupling: Task 4.
- Keeps fix scoped to source stream error handling: no parser, imgproxy encrypted URL, cache API, or Req transport changes.
- Adds focused tests without sleeps: Task 1.
- Runs required verification commands: Task 5.
- Uses `mise exec -- ...`: every repository command does.

Placeholder scan:

- No TBD placeholders.
- Code-changing steps include exact code or an exact replacement.
- Test steps include exact commands and expected results.

Type consistency:

- Source stream exceptions remain `%ImagePlug.Source.StreamError{reason: reason}`.
- Request-facing source errors remain `{:error, {:source, reason}}`.
- Boundary success and error results preserve the wrapped function's tuple shape unless a source stream exception or linked exit happens.
