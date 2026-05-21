# Simplify Source Stream Decode Boundary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove request-mailbox coupling from `ImagePlug.Source.WrappedStream` while preserving the PR #86 CI fix: deferred source stream failures must return `{:error, {:source, reason}}` / HTTP 422 instead of leaking linked process exits.

**Architecture:** Keep source streams responsible only for stream validation: chunk shape, byte limits, cleanup, and normalized `%ImagePlug.Source.StreamError{}` raises. Move Vix/Image linked-process containment into request decode orchestration, where ImagePlug calls an external decoder that uses `spawn_link/1` internally. The request boundary should own `trap_exit`, source-error conversion, and any post-decode/materialization checks.

**Tech Stack:** Elixir, ExUnit, Plug tests, `Image.open/2`, Vix streaming source pipes, `mise exec -- ...`.

---

## Current Problem

The current branch fixed the CI race by adding `error_receiver` to `ImagePlug.Source.WrappedStream` and `ImagePlug.Source.forward_stream_errors/2`. That works, but it makes the source enumerable send request-process mailbox messages:

```elixir
send(receiver, {:source_stream_error, self(), error})
```

That is the wrong ownership direction. Source streams should not know that request decoding has a mailbox protocol. The linked-exit leak is caused by `Image.open/2` / Vix decode behavior, so the ugly process containment belongs in `ImagePlug.Request.Processor`.

Keep these existing contracts:

- Direct enumeration of wrapped streams raises `%ImagePlug.Source.StreamError{}`.
- Bad chunks become `:invalid_stream_chunk`.
- Over-limit bodies become `:body_too_large`.
- Raw upstream enumerable failures become `:stream_exception`.
- Request decoding converts source stream failures into source errors.
- The wire-level request safety test at `test/image_plug/request_safety_test.exs:309` keeps returning HTTP 422.

## Files

- Modify: `lib/image_plug/source/wrapped_stream.ex`
  - Remove `error_receiver`.
  - Remove request mailbox notification.
  - Keep only stream validation and `%ImagePlug.Source.StreamError{}` normalization.
- Modify: `lib/image_plug/source.ex`
  - Remove `forward_stream_errors/2`.
  - Keep `wrap_response/2` returning `%ImagePlug.Source.WrappedStream{stream: stream, max_body_bytes: max_body_bytes}`.
- Modify: `lib/image_plug/request/processor.ex`
  - Remove `Source.forward_stream_errors/2` call.
  - Replace `with_source_stream_exit_trap/1` with a request-owned helper that names the decode/materialization boundary and converts source stream exits.
- Modify: `test/image_plug/source_test.exs`
  - Add a source-level regression that `WrappedStream` has no request notification behavior and still raises for direct callers.
- Modify: `test/image_plug/processor_test.exs`
  - Add processor-level tests that prove source stream failures are converted by request decode orchestration, not by `WrappedStream.error_receiver`.
- Keep: `test/image_plug/request_safety_test.exs`
  - The existing wire-level test is the public CI contract; do not add sleeps.

## Task 1: Lock Source Stream Back To A Plain Enumerable

**Files:**
- Modify: `test/image_plug/source_test.exs`
- Modify: `lib/image_plug/source/wrapped_stream.ex`
- Modify: `lib/image_plug/source.ex`

- [ ] **Step 1: Write the failing source test**

Add this test after `"wrapped streams preserve safe deferred source errors"` in `test/image_plug/source_test.exs`:

```elixir
  test "wrapped streams do not send request boundary messages" do
    response = %Response{
      stream: Stream.map([:error], fn _ -> raise Source.StreamError, reason: :bad_status end)
    }

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 20)

    error = assert_raise Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
    assert error.reason == :bad_status
    refute_received {:source_stream_error, _pid, _error}
  end
```

- [ ] **Step 2: Run the source test to verify current behavior**

Run:

```bash
mise exec -- mix test test/image_plug/source_test.exs
```

Expected before implementation: this may pass on the current branch because `error_receiver` defaults to `nil`. That is acceptable for this task; it locks the source contract before deleting the request-coupling field.

- [ ] **Step 3: Simplify `ImagePlug.Source.WrappedStream`**

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

- [ ] **Step 4: Remove `Source.forward_stream_errors/2`**

In `lib/image_plug/source.ex`, delete this function block:

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

Keep `wrap_response/2` as:

```elixir
  @spec wrap_response(Response.t(), keyword()) :: {:ok, Response.t()} | {:error, error()}
  def wrap_response(%Response{stream: stream}, runtime_opts) when is_list(runtime_opts) do
    max_body_bytes = Keyword.get(runtime_opts, :max_body_bytes, :infinity)
    {:ok, %Response{stream: %WrappedStream{stream: stream, max_body_bytes: max_body_bytes}}}
  end

  def wrap_response(_response, _runtime_opts), do: {:error, {:source, :invalid_adapter_result}}
```

- [ ] **Step 5: Run focused source tests**

Run:

```bash
mise exec -- mix test test/image_plug/source_test.exs
```

Expected: all source tests pass.

- [ ] **Step 6: Commit the source simplification**

Run:

```bash
git add lib/image_plug/source.ex lib/image_plug/source/wrapped_stream.ex test/image_plug/source_test.exs
git commit -m "Simplify wrapped source streams"
```

## Task 2: Move Source Stream Failure Conversion Into Request Decode

**Files:**
- Modify: `test/image_plug/processor_test.exs`
- Modify: `lib/image_plug/request/processor.ex`

- [ ] **Step 1: Add a focused processor test for linked stream exits**

In `test/image_plug/processor_test.exs`, add this helper module after `DecodeRaisesSourceStreamError`:

```elixir
  defmodule DecodeSpawnsLinkedStreamReader do
    def open(stream, _decode_options) do
      parent = self()

      spawn_link(fn ->
        send(parent, :linked_reader_started)
        Enum.to_list(stream)
        send(parent, :linked_reader_finished)
      end)

      receive do
        :linked_reader_started -> :ok
      end

      {:error, :decode_after_source_pipe_closed}
    end
  end
```

Then add this test after `"deferred source stream errors remain source errors during decode"`:

```elixir
  test "linked source stream reader exits remain source errors during decode" do
    response = %Response{stream: Stream.map([:raise], fn _ -> raise "raw stream failure" end)}
    assert {:ok, response} = Source.wrap_response(response, max_body_bytes: 20)

    assert {:error, {:source, :stream_exception}} =
             Processor.decode_validate_source_response(
               response,
               plan(),
               Keyword.put(opts(), :image_open_module, DecodeSpawnsLinkedStreamReader)
             )
  end
```

- [ ] **Step 2: Run the processor test and verify it fails after Task 1**

Run:

```bash
mise exec -- mix test test/image_plug/processor_test.exs
```

Expected after Task 1 and before request-boundary implementation: the new test fails because the linked reader can exit with `%ImagePlug.Source.StreamError{}` after `open/2` returns its decode error, and there is no `WrappedStream.error_receiver` fallback.

- [ ] **Step 3: Replace `decode_source_response/3` with request-owned containment**

In `lib/image_plug/request/processor.ex`, replace:

```elixir
  defp decode_source_response(%Source.Response{} = source_response, decode_options, opts) do
    image_open_module = Keyword.get(opts, :image_open_module, Image)
    source_response = Source.forward_stream_errors(source_response, self())

    with_source_stream_exit_trap(fn ->
      image_open_module.open(source_response.stream, decode_options)
    end)
  rescue
    exception in [Source.StreamError] -> {:error, {:source, exception.reason}}
  catch
    :exit, {%Source.StreamError{reason: reason}, _stacktrace} -> {:error, {:source, reason}}
    :exit, %Source.StreamError{reason: reason} -> {:error, {:source, reason}}
  end
```

with:

```elixir
  defp decode_source_response(%Source.Response{} = source_response, decode_options, opts) do
    image_open_module = Keyword.get(opts, :image_open_module, Image)

    with_source_stream_boundary(fn ->
      image_open_module.open(source_response.stream, decode_options)
    end)
  end
```

Then replace `with_source_stream_exit_trap/1` and `receive_source_stream_exit/1` with:

```elixir
  defp with_source_stream_boundary(fun) when is_function(fun, 0) do
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
    :exit, {%Source.StreamError{reason: reason}, _stacktrace} ->
      {:error, {:source, reason}}

    :exit, %Source.StreamError{reason: reason} ->
      {:error, {:source, reason}}
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
```

This intentionally keeps the containment in `Processor`. If the new test still races, do not add sleeps. Continue to Task 3 and move the boundary around materialization rather than adding mailbox protocol back to `WrappedStream`.

- [ ] **Step 4: Run the processor test**

Run:

```bash
mise exec -- mix test test/image_plug/processor_test.exs
```

Expected: the new linked-reader test passes, and the existing decode-source-error test passes.

- [ ] **Step 5: Run the wire-level CI regression**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs:309 --repeat-until-failure 50
```

Expected: 50 runs pass. The output should not include an uncaught `ImagePlug.Source.StreamError` exit from the request process.

- [ ] **Step 6: Commit the request-boundary move**

Run:

```bash
git add lib/image_plug/request/processor.ex test/image_plug/processor_test.exs
git commit -m "Move source stream errors to decode boundary"
```

## Task 3: Cover Sequential Materialization Without Source Mailbox Coupling

**Files:**
- Modify: `test/image_plug/processor_test.exs`
- Modify: `lib/image_plug/request/processor.ex`

- [ ] **Step 1: Add a test for source errors deferred until materialization**

In `test/image_plug/processor_test.exs`, add this helper module near the existing test helper modules:

```elixir
  defmodule MaterializerRaisesSourceStreamError do
    def materialize(_state, _opts) do
      raise Source.StreamError, reason: :stream_exception
    end
  end
```

Then add this test after `"process_source materializes between pipelines before executing the next pipeline"`:

```elixir
  test "source stream errors during materialization remain source errors" do
    {:ok, operation} = resize_fit(120, :auto)

    plan = %Plan{
      source: %Path{segments: ["images", "beach.jpg"]},
      pipelines: [%Pipeline{operations: [operation]}],
      output: %Output{mode: {:explicit, :jpeg}}
    }

    opts =
      opts()
      |> Keyword.put(:image_materializer, MaterializerRaisesSourceStreamError)

    assert {:error, {:source, :stream_exception}} =
             Processor.process_source(plan, resolved_source(), opts)
  end
```

- [ ] **Step 2: Run the processor test and verify it fails**

Run:

```bash
mise exec -- mix test test/image_plug/processor_test.exs
```

Expected before implementation: the new materializer test fails because `materialize_before_delivery/3` currently wraps materializer failures as `{:error, {:decode, materialize_error}}` or lets `%Source.StreamError{}` escape outside the source-stream boundary.

- [ ] **Step 3: Apply the source-stream boundary to materialization**

In `lib/image_plug/request/processor.ex`, change `materialize_state/2` from:

```elixir
  defp materialize_state(%State{} = state, opts) do
    materializer =
      Keyword.get(
        opts,
        :image_materializer,
        Keyword.get(opts, :image_materializer_module, Materializer)
      )

    materializer.materialize(state, opts)
  end
```

to:

```elixir
  defp materialize_state(%State{} = state, opts) do
    materializer =
      Keyword.get(
        opts,
        :image_materializer,
        Keyword.get(opts, :image_materializer_module, Materializer)
      )

    with_source_stream_boundary(fn ->
      materializer.materialize(state, opts)
    end)
  end
```

Then add this clause before the existing generic materialize error wrapper:

```elixir
  defp handle_materialization_result({:error, {:source, _reason}} = error), do: error
```

The materialization result handlers should be ordered like this:

```elixir
  defp handle_materialization_result({:error, {:source, _reason}} = error), do: error
  defp handle_materialization_result({:error, {:config, _reason} = error}), do: {:error, error}

  defp handle_materialization_result({:error, materialize_error}),
    do: {:error, {:decode, materialize_error}}

  defp handle_materialization_result({:ok, %State{} = state}), do: {:ok, state}
```

- [ ] **Step 4: Run the processor test**

Run:

```bash
mise exec -- mix test test/image_plug/processor_test.exs
```

Expected: all processor tests pass.

- [ ] **Step 5: Run the request safety file**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs
```

Expected: all request safety tests pass.

- [ ] **Step 6: Commit materialization boundary handling**

Run:

```bash
git add lib/image_plug/request/processor.ex test/image_plug/processor_test.exs
git commit -m "Handle source stream errors during materialization"
```

## Task 4: Final Verification And Push

**Files:**
- Verify only.

- [ ] **Step 1: Format touched files**

Run:

```bash
mise exec -- mix format lib/image_plug/source.ex lib/image_plug/source/wrapped_stream.ex lib/image_plug/request/processor.ex test/image_plug/source_test.exs test/image_plug/processor_test.exs
```

Expected: command exits 0.

- [ ] **Step 2: Run focused source tests**

Run:

```bash
mise exec -- mix test test/image_plug/source_test.exs
```

Expected: all tests pass.

- [ ] **Step 3: Run focused processor tests**

Run:

```bash
mise exec -- mix test test/image_plug/processor_test.exs
```

Expected: all tests pass.

- [ ] **Step 4: Run focused request safety tests**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Repeat the original CI failure**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs:309 --repeat-until-failure 100
```

Expected: all 100 runs pass.

- [ ] **Step 6: Run the full suite**

Run:

```bash
mise exec -- mix test
```

Expected: all tests, doctests, and properties pass.

- [ ] **Step 7: Compile with warnings as errors**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: command exits 0. Dependency warnings may print, but the project compile must succeed.

- [ ] **Step 8: Inspect the final diff**

Run:

```bash
git diff --stat HEAD~3..HEAD
git diff HEAD~3..HEAD -- lib/image_plug/source/wrapped_stream.ex lib/image_plug/source.ex lib/image_plug/request/processor.ex test/image_plug/source_test.exs test/image_plug/processor_test.exs
```

Expected:

- `WrappedStream` has no `error_receiver`.
- `Source` has no `forward_stream_errors/2`.
- `Processor` owns all `%Source.StreamError{}` rescue/catch conversion.
- No sleeps were added.
- No imgproxy encrypted URL behavior changed.

- [ ] **Step 9: Push the branch**

Run:

```bash
git push
```

Expected: `fix-source-stream-exit-race` updates on `origin`.

## Test Impact

Keep existing tests:

- `test/image_plug/request_safety_test.exs:309` remains the wire-level public contract.
- Existing `Source.wrap_response/2` tests keep source boundary behavior.

Add tests only where they prove ownership:

- `WrappedStream` is a plain enumerable and does not send request mailbox messages.
- `Processor` converts linked source stream exits.
- `Processor` converts source stream failures during materialization.

Do not add tests that scan source text for deleted function names. Behavior and boundary tests are enough.

## Risks

- Vix/Image may defer source reads farther than `Image.open/2`. That is why Task 3 wraps materialization too.
- If the linked stream reader can still fail after request processing has moved past materialization, the design needs another discussion before adding more process plumbing. Do not reintroduce `error_receiver` as a fallback without proving that later lifecycle.
- Avoid sleeps. A race fix that depends on timing is not a fix.

## Self-Review

Spec coverage:

- Removes source-to-request mailbox coupling: Task 1.
- Keeps source validation and body limits: Task 1.
- Keeps request source-error conversion: Tasks 2 and 3.
- Avoids imgproxy encrypted URL behavior: no imgproxy files are touched.
- Uses focused tests and no sleeps: Tasks 1-4.
- Uses `mise exec -- ...`: every command does.

Placeholder scan:

- No TBD/TODO placeholders.
- Every code-changing step includes concrete code.

Type consistency:

- All source errors use `%ImagePlug.Source.StreamError{reason: reason}`.
- Request-facing source errors remain `{:error, {:source, reason}}`.
- Materializer source errors are preserved before generic decode wrapping.
