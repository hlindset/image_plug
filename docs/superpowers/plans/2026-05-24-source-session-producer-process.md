# Source Session Producer Process Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move lazy encoder enumeration out of `ImagePlug.Request.SourceSession` so the session GenServer coordinates lifecycle while a separate producer process owns source-backed stream work.

**Architecture:** `SourceSession` remains the request lifecycle coordinator: it monitors the request owner, gates cache commit/abort, and replies to `prepare/1`, `next/1`, and `cancel/1`. A new private producer process owns fetch/decode/transform/output resolution, the `Image.stream!/2` enumerable, and the suspended `Enumerable.reduce/3` continuation. The producer only emits one chunk per explicit demand, so response delivery remains pull-based and `Response.Sender` stays unchanged.

**Tech Stack:** Elixir, OTP processes, `GenServer`, `Enumerable.reduce/3` suspension, ExUnit, Boundary, pinned Vix fork `3a30758d44526d3c914b2076bd0be201c972f2b7`, `mise exec -- mix`.

---

## Preconditions

The current branch is `source-session-prepared-stream-routing`.

The latest SourceSession cleanup is committed in `ca45769 Tighten source session shutdown semantics`.

`mix.exs` must keep Vix pinned to:

```elixir
{:vix,
 git: "https://github.com/hlindset/vix.git",
 ref: "3a30758d44526d3c914b2076bd0be201c972f2b7",
 override: true}
```

Run Vix-related tests with:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test ...
```

This is a refactor slice. It should preserve the external request/response behavior from Slice 5 and the current transactional cache sink work. Don't change `Response.Sender`, `Response.PreparedStream`, cache adapter interfaces, cache sink interfaces, or public docs.

## Files

- Create: `lib/image_plug/request/source_session/producer.ex`
- Create: `test/image_plug/request/source_session/producer_test.exs`
- Modify: `lib/image_plug/request/source_session.ex`
- Modify: `test/image_plug/request/source_session_test.exs`
- Modify: `test/image_plug/request/source_session_supervisor_test.exs`
- Modify: `test/image_plug/request/vix_stream_continuation_test.exs`
- Read as needed: `lib/image_plug/request/source_session/request.ex`
- Read as needed: `lib/image_plug/request/source_session/prepared.ex`
- Read as needed: `lib/image_plug/request/source_session_supervisor.ex`
- Read as needed: `lib/image_plug/output/encoder.ex`
- Read as needed: `lib/image_plug/request/processor.ex`
- Read as needed: `lib/image_plug/response/sender.ex`
- Read as needed: `docs/superpowers/designs/2026-05-21-source-session-lifecycle-boundary.md`

## Non-Goals

- Don't add cache tee features.
- Don't change `Response.Sender`.
- Don't change `Response.PreparedStream`.
- Don't change cache sink behavior.
- Don't introduce `:gen_statem`.
- Don't add a new application supervisor for producers.
- Don't reintroduce the removed direct image response path.
- Don't make `SourceSession.Producer` public outside the request boundary.

## Target Contract

`SourceSession` should no longer enumerate lazy image streams inside `handle_call/3`.

`SourceSession` should no longer manually drain arbitrary `{:EXIT, ...}` messages while servicing `prepare/1` or `next/1`. It should handle only explicit owner monitor messages, producer monitor messages, producer result messages, call messages, and controlled parent shutdown.

`SourceSession` should enforce single-flight producer demand. At most one `prepare/1` or `next/1` caller may be pending. A concurrent `prepare/1` or `next/1` call while `pending != nil` must receive `{:error, {:protocol, :busy}}` immediately and must not enqueue another producer demand. `cancel/1` may interrupt a pending demand, but it must reply to the pending caller before stopping the session.

The producer should own:

- source fetch/decode/validation
- transform execution
- output resolution
- encoder stream construction
- suspended `{acc, continuation}` state
- stream halt on graceful cancel

The producer should be demand-driven:

- first demand returns `{:ok, {:first_chunk, chunk, content_type, headers, resolved_output}}`
- later demand returns `{:ok, {:chunk, chunk}}`
- normal completion returns `{:ok, :done}`
- failures return `{:error, reason}` or cause producer `:DOWN`

The producer must be linked to `SourceSession` when started by the session. The monitor gives `SourceSession` a reason to classify; the link prevents an orphan producer if the session is killed while the producer is blocked inside source or encoder work. Tests that start a producer directly should trap exits only when they intentionally kill it.

`SourceSession` should own:

- request owner monitor
- producer monitor
- pending caller references
- `Prepared` construction
- cache sink open/write/commit/abort
- translating producer failures into the existing `SourceSession.prepare/1` and `SourceSession.next/1` return shapes

When owner death arrives while `prepare/1` or `next/1` is waiting on the producer, `SourceSession` should reply to the pending caller with:

```elixir
{:error, {:session, {:shutdown, {:owner_down, reason}}}}
```

Then it should abort cache staging and stop.

If the producer is idle and has a continuation, explicit `cancel/1` should ask it to halt the continuation and wait for an acknowledgement within the existing bounded cancel timeout. If the producer is busy or doesn't respond, `SourceSession` should stop the producer process and continue cleanup. If another caller is already pending, `cancel/1` should reply to that caller with `{:error, {:session, :cancelled}}` before stopping. Runtime cleanup failures after headers commit are diagnostic; they must not become client-visible HTTP errors.

## Task 1: Add The Producer Protocol Tests

Create focused tests for the new producer before changing `SourceSession`.

**Files:**
- Create: `test/image_plug/request/source_session/producer_test.exs`

- [ ] **Step 1: Add the producer test module and fixtures**

Create `test/image_plug/request/source_session/producer_test.exs`:

```elixir
defmodule ImagePlug.Request.SourceSession.ProducerTest do
  use ExUnit.Case, async: false

  alias ImagePlug.Output.Policy
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Path
  alias ImagePlug.Request.SourceSession.Producer
  alias ImagePlug.Request.SourceSession.Request
  alias ImagePlug.Source.Resolved, as: ResolvedSource
  alias ImagePlug.SourceTest.ValidAdapter

  @event_target __MODULE__.StreamEvents

  defmodule MultiChunkImage do
    def stream!(_image, suffix: ".jpg"), do: ["first chunk", "second chunk"]
  end

  defmodule CleanupStreamImage do
    @event_target ImagePlug.Request.SourceSession.ProducerTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :second}
          :second -> {["second chunk"], :done}
          :done -> {:halt, :done}
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:stream_finalized, state})
          end
        end
      )
    end
  end

  defmodule RaisingAfterFirstChunkImage do
    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :raise}
          :raise -> raise "boom after first chunk"
        end,
        fn _state -> :ok end
      )
    end
  end

  defmodule BlockingImage do
    @event_target ImagePlug.Request.SourceSession.ProducerTest.StreamEvents

    def stream!(_image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first ->
            {["first chunk"], :second}

          :second ->
            if target = Process.whereis(@event_target) do
              send(target, {:producer_blocked, self()})
            end

            receive do
              :continue -> {["second chunk"], :done}
            end

          :done ->
            {:halt, :done}
        end,
        fn state ->
          if target = Process.whereis(@event_target) do
            send(target, {:blocking_stream_finalized, state})
          end
        end
      )
    end
  end

  setup do
    Process.flag(:trap_exit, true)
    if Process.whereis(@event_target), do: Process.unregister(@event_target)
    Process.register(self(), @event_target)
    on_exit(fn -> if Process.whereis(@event_target), do: Process.unregister(@event_target) end)
    :ok
  end

  test "producer returns first chunk, later chunks, and done on demand" do
    {:ok, producer} = Producer.start_link(request(opts: opts(image_module: MultiChunkImage)))
    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, "first chunk", "image/jpeg", [], resolved_output}} =
             Producer.next(producer)

    assert resolved_output.format == :jpeg
    assert {:ok, {:chunk, "second chunk"}} = Producer.next(producer)
    assert {:ok, :done} = Producer.next(producer)
    assert_receive {:DOWN, ^ref, :process, ^producer, :normal}
  end

  test "producer halt runs the suspended stream cleanup callback when idle" do
    {:ok, producer} = Producer.start_link(request(opts: opts(image_module: CleanupStreamImage)))
    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, "first chunk", "image/jpeg", [], _resolved_output}} =
             Producer.next(producer)

    assert :ok = Producer.halt(producer)
    assert_receive {:stream_finalized, :second}
    assert_receive {:DOWN, ^ref, :process, ^producer, :normal}
  end

  test "producer returns post-first-chunk encoder errors" do
    {:ok, producer} =
      Producer.start_link(request(opts: opts(image_module: RaisingAfterFirstChunkImage)))

    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, "first chunk", "image/jpeg", [], _resolved_output}} =
             Producer.next(producer)

    assert {:error, {:encode, %RuntimeError{message: "boom after first chunk"}, stacktrace}} =
             Producer.next(producer)

    assert is_list(stacktrace)
    assert_receive {:DOWN, ^ref, :process, ^producer, :normal}
  end

  test "producer can be stopped while a demand is blocked" do
    {:ok, producer} = Producer.start_link(request(opts: opts(image_module: BlockingImage)))
    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, "first chunk", "image/jpeg", [], _resolved_output}} =
             Producer.next(producer)

    parent = self()

    caller =
      spawn(fn ->
        send(parent, {:next_result, Producer.next(producer, 5_000)})
      end)

    caller_ref = Process.monitor(caller)

    assert_receive {:producer_blocked, ^producer}
    Process.exit(producer, :shutdown)

    assert_receive {:DOWN, ^ref, :process, ^producer, :shutdown}
    assert_receive {:next_result, {:error, {:producer, {:exit, :shutdown}}}}
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
  end

  defp request(opts: runtime_opts) do
    %Request{
      plan: plan(),
      resolved_source: resolved_source(),
      output_policy: Policy.from_output_plan(Plug.Test.conn(:get, "/"), %Output{mode: {:explicit, :jpeg}}, runtime_opts),
      opts: runtime_opts,
      cache_key: nil
    }
  end

  defp plan do
    %Plan{
      source: %Path{segments: ["images", "beach.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: %Output{mode: {:explicit, :jpeg}}
    }
  end

  defp resolved_source(fetch \\ {:ok, image_body()}) do
    %ResolvedSource{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]],
      fetch: fetch,
      cache: :normal
    }
  end

  defp opts(extra) do
    Keyword.merge(
      [
        sources: %{path: {ValidAdapter, []}},
        image_module: MultiChunkImage,
        output_formats: [jpeg: []],
        output_negotiation: []
      ],
      extra
    )
  end

  defp image_body do
    File.read!("test/fixtures/images/beach.jpg")
  end
end
```

- [ ] **Step 2: Run the producer tests and verify they fail**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session/producer_test.exs
```

Expected: FAIL because `ImagePlug.Request.SourceSession.Producer` doesn't exist.

## Task 2: Implement The Producer

Add a private producer process that owns lazy stream state. Keep it demand-driven.

**Files:**
- Create: `lib/image_plug/request/source_session/producer.ex`
- Modify if needed: `test/image_plug/request/source_session/producer_test.exs`

- [ ] **Step 1: Create the producer module**

Create `lib/image_plug/request/source_session/producer.ex`:

```elixir
defmodule ImagePlug.Request.SourceSession.Producer do
  @moduledoc false

  alias ImagePlug.Output.Encoder
  alias ImagePlug.Output.Policy
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Request.Processor
  alias ImagePlug.Request.Processor.Decoded
  alias ImagePlug.Request.SourceSession.Request
  alias ImagePlug.Source.StreamError
  alias ImagePlug.Transform.State

  @call_timeout 15_000
  @halt_timeout 2_000

  defstruct [
    :request,
    :stream_state,
    :resolved_output,
    :content_type,
    prepared?: false
  ]

  @type t() :: pid()

  @spec start_link(Request.t(), keyword()) :: {:ok, pid()}
  def start_link(%Request{} = request, opts \\ []) do
    caller_chain = Keyword.get(opts, :caller_chain, Process.get(:"$callers", []))

    pid =
      spawn_link(fn ->
        Process.put(:"$callers", caller_chain)
        loop(%__MODULE__{request: request})
      end)

    {:ok, pid}
  end

  # This is an internal single-flight demand primitive. SourceSession must guard
  # `pending == nil` before calling it; Producer.next/2 uses it only for focused
  # tests and is non-retryable after timeout.
  @spec request_next(pid(), pid()) :: reference()
  def request_next(pid, receiver) when is_pid(pid) and is_pid(receiver) do
    ref = make_ref()
    send(pid, {:next, receiver, ref})
    ref
  end

  @spec next(pid(), timeout()) ::
          {:ok, {:first_chunk, binary(), String.t(), [{String.t(), String.t()}], Resolved.t()}}
          | {:ok, {:chunk, binary()}}
          | {:ok, :done}
          | {:error, term()}
  def next(pid, timeout \\ @call_timeout) when is_pid(pid) do
    monitor_ref = Process.monitor(pid)
    ref = request_next(pid, self())
    receive_reply_or_down(ref, monitor_ref, pid, timeout)
  end

  @spec halt(pid(), timeout()) :: :ok | {:error, term()}
  def halt(pid, timeout \\ @halt_timeout) when is_pid(pid) do
    monitor_ref = Process.monitor(pid)
    ref = make_ref()
    send(pid, {:halt, self(), ref})
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

  defp loop(%__MODULE__{} = state) do
    receive do
      {:next, caller, ref} ->
        case next_result(state) do
          {:reply, reply, state} ->
            send(caller, {ref, reply})
            loop(state)

          {:stop, reply} ->
            # Domain failures are terminal protocol replies. After sending one,
            # the producer exits normally; unexpected process death is reported
            # by SourceSession's producer monitor.
            send(caller, {ref, reply})
            exit(:normal)
        end

      {:halt, caller, ref} ->
        reply = halt_stream(state)
        send(caller, {ref, reply})
        exit(:normal)
    end
  end

  defp next_result(%__MODULE__{prepared?: false} = state) do
    case prepare_first_chunk(state) do
      {:ok, chunk, state} ->
        reply =
          {:ok,
           {:first_chunk, chunk, state.content_type, state.resolved_output.response_headers,
            state.resolved_output}}

        {:reply, reply, %{state | prepared?: true}}

      :empty ->
        {:stop, {:error, {:encode, :empty_stream}}}

      {:error, reason} ->
        {:stop, {:error, reason}}
    end
  end

  defp next_result(%__MODULE__{stream_state: nil}) do
    {:stop, {:ok, :done}}
  end

  defp next_result(%__MODULE__{stream_state: {acc, continuation}} = state) do
    case continue_stream(acc, continuation, %{state | stream_state: nil}) do
      {:ok, chunk, state} -> {:reply, {:ok, {:chunk, chunk}}, state}
      :done -> {:stop, {:ok, :done}}
      {:error, reason} -> {:stop, {:error, reason}}
    end
  end

  defp prepare_first_chunk(%__MODULE__{request: %Request{} = request} = state) do
    with {:ok, %Decoded{} = decoded} <-
           Processor.fetch_decode_validate_source_with_source_format(
             request.plan,
             request.resolved_source,
             request.opts
           ),
         {:ok, %State{} = final_state} <-
           Processor.process_decoded_source(decoded, request.plan, request.opts),
         {:ok, %Resolved{} = resolved_output} <-
           resolve_output(request.output_policy, decoded.source_format, final_state.image),
         {:ok, stream, content_type} <-
           Encoder.stream_output(final_state.image, resolved_output, request.opts),
         {:ok, chunk, stream_state} <- reduce_stream(stream) do
      {:ok, chunk,
       %{
         state
         | stream_state: stream_state,
           resolved_output: resolved_output,
           content_type: content_type
       }}
    else
      :empty -> :empty
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception in [StreamError] -> {:error, {:source, exception.reason}}
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  catch
    :exit, {%StreamError{reason: reason}, _stacktrace} -> {:error, {:source, reason}}
    :exit, %StreamError{reason: reason} -> {:error, {:source, reason}}
    :exit, reason -> {:error, {:producer, {:exit, reason}}}
    kind, reason -> {:error, {:producer, {kind, reason}}}
  end

  defp resolve_output(%Policy{} = policy, source_format, image) do
    case Policy.resolve(policy, source_format) do
      {:ok, %Resolved{} = resolved_output} ->
        {:ok, resolved_output}

      {:needs_final_image_alpha, :source} ->
        {:ok, Policy.resolve_final_image_alpha(policy, Image.has_alpha?(image))}

      {:needs_encoded_evaluation} ->
        {:error, {:output, :encoded_evaluation_not_supported}}

      {:error, reason} ->
        {:error, {:output, reason}}
    end
  end

  defp continue_stream(acc, continuation, state) do
    continuation.({:cont, acc})
    |> reduce_result(state)
  rescue
    exception in [StreamError] -> {:error, {:source, exception.reason}}
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  catch
    :exit, {%StreamError{reason: reason}, _stacktrace} -> {:error, {:source, reason}}
    :exit, %StreamError{reason: reason} -> {:error, {:source, reason}}
    kind, reason -> {:error, {:encode, {kind, reason}, []}}
  end

  defp reduce_stream(stream) do
    result =
      Enumerable.reduce(stream, {:cont, nil}, fn
        chunk, _acc when is_binary(chunk) and byte_size(chunk) > 0 -> {:suspend, chunk}
        _chunk, acc -> {:cont, acc}
      end)

    case result do
      {:suspended, chunk, continuation} when is_binary(chunk) ->
        {:ok, chunk, {chunk, continuation}}

      {:done, _acc} ->
        :empty

      {:halted, _acc} ->
        :empty
    end
  end

  defp reduce_result({:suspended, chunk, continuation}, state) when is_binary(chunk) do
    {:ok, chunk, %{state | stream_state: {chunk, continuation}}}
  end

  defp reduce_result({:done, _acc}, _state), do: :done
  defp reduce_result({:halted, _acc}, _state), do: :done

  defp halt_stream(%__MODULE__{stream_state: nil}), do: :ok

  defp halt_stream(%__MODULE__{stream_state: {acc, continuation}}) do
    continuation.({:halt, acc})
    :ok
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
```

- [ ] **Step 2: Run the producer tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session/producer_test.exs
```

Expected: PASS.

- [ ] **Step 3: Commit the producer**

Run:

```bash
mise exec -- git add lib/image_plug/request/source_session/producer.ex test/image_plug/request/source_session/producer_test.exs
mise exec -- git commit -m "Add source session producer process"
```

## Task 3: Refactor SourceSession Around Producer Demand

Make `SourceSession` coordinate a producer instead of reducing the encoder stream inside `handle_call/3`.

**Files:**
- Modify: `lib/image_plug/request/source_session.ex`
- Modify: `test/image_plug/request/source_session_test.exs`
- Modify: `test/image_plug/request/source_session_supervisor_test.exs`

- [ ] **Step 1: Add SourceSession tests for pending prepare and next cancellation**

Edit `test/image_plug/request/source_session_test.exs`.

Add a blocking image that proves `SourceSession` can process owner death while a producer demand is in flight:

```elixir
defmodule ProducerBlockedBeforeSecondChunkImage do
  @event_target ImagePlug.Request.SourceSessionTest.StreamEvents

  def stream!(_image, suffix: ".jpg") do
    Stream.resource(
      fn -> :first end,
      fn
        :first ->
          {["first chunk"], :second}

        :second ->
          if target = Process.whereis(@event_target) do
            send(target, {:producer_blocked_before_second_chunk, self()})
          end

          receive do
            :continue_second_chunk -> {["second chunk"], :done}
          end

        :done ->
          {:halt, :done}
      end,
      fn state ->
        if target = Process.whereis(@event_target) do
          send(target, {:producer_blocked_stream_finalized, state})
        end
      end
    )
  end
end
```

Add this test near the existing owner-death tests:

```elixir
test "owner death during in-flight next skips waiting for producer continuation" do
  register_stream_events!()
  attach_telemetry([[:image_plug, :cache, :stage]])

  owner =
    spawn(fn ->
      receive do
        :stop_owner -> :ok
      end
    end)

  {:ok, session} =
    SourceSession.start(
      cached_request(opts: opts(image_module: ProducerBlockedBeforeSecondChunkImage)),
      owner: owner,
      parent: self()
    )

  session_ref = Process.monitor(session)
  owner_ref = Process.monitor(owner)

  assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

  parent = self()

  caller =
    spawn(fn ->
      send(parent, {:next_result, SourceSession.next(session, 5_000)})
    end)

  caller_ref = Process.monitor(caller)

  assert_receive {:producer_blocked_before_second_chunk, producer_pid}
  producer_ref = Process.monitor(producer_pid)
  send(owner, :stop_owner)
  assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

  assert_receive {:next_result, {:error, {:session, {:shutdown, {:owner_down, :normal}}}}}
  assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
  assert_receive {:DOWN, ^producer_ref, :process, ^producer_pid, :shutdown}
  assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}
  refute_received {:cache_commit_sink, _chunks}
  assert_received {:cache_abort_sink, ["first chunk"]}

  assert_receive {:telemetry_event, [:image_plug, :cache, :stage], _measurements,
                  %{
                    result: :ok,
                    cache: :stage_abandoned,
                    reason: :owner_down,
                    output_format: :jpeg
                  }}
end
```

This test intentionally doesn't assert the custom stream cleanup callback ran. When owner death interrupts an active producer continuation, the session stops the producer process instead of waiting for the continuation to yield. The Vix fork fix is the resource-safety backstop for the real encoder path.

Add the matching pending-prepare test. This uses the existing blocking source fixture so the first producer demand is stuck before headers commit:

```elixir
test "owner death during in-flight prepare replies and stops producer" do
  owner =
    spawn(fn ->
      receive do
        :stop_owner -> :ok
      end
    end)

  {:ok, session} = SourceSession.start(blocking_request(), owner: owner, parent: self())
  session_ref = Process.monitor(session)
  owner_ref = Process.monitor(owner)
  parent = self()

  caller =
    spawn(fn ->
      send(parent, {:prepare_result, SourceSession.prepare(session, 5_000)})
    end)

  caller_ref = Process.monitor(caller)

  assert_receive {:fetch_started, producer_pid}
  producer_ref = Process.monitor(producer_pid)
  send(owner, :stop_owner)
  assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

  assert_receive {:prepare_result, {:error, {:session, {:shutdown, {:owner_down, :normal}}}}}
  assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
  assert_receive {:DOWN, ^producer_ref, :process, ^producer_pid, :shutdown}
  assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, {:owner_down, :normal}}}
end
```

Add explicit single-flight tests for the new protocol guard:

```elixir
test "concurrent next while producer demand is pending returns busy" do
  register_stream_events!()

  {:ok, session} =
    SourceSession.start(
      cached_request(opts: opts(image_module: ProducerBlockedBeforeSecondChunkImage)),
      parent: self()
    )

  assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
  parent = self()

  caller =
    spawn(fn ->
      send(parent, {:first_next, SourceSession.next(session, 5_000)})
    end)

  caller_ref = Process.monitor(caller)
  assert_receive {:producer_blocked_before_second_chunk, producer_pid}

  assert {:error, {:protocol, :busy}} = SourceSession.next(session)

  send(producer_pid, :continue_second_chunk)
  assert_receive {:first_next, {:chunk, "second chunk"}}
  assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
end

test "concurrent prepare while producer demand is pending returns busy" do
  {:ok, session} = SourceSession.start(blocking_request(), parent: self())
  parent = self()

  caller =
    spawn(fn ->
      send(parent, {:first_prepare, SourceSession.prepare(session, 5_000)})
    end)

  caller_ref = Process.monitor(caller)
  assert_receive {:fetch_started, producer_pid}

  assert {:error, {:protocol, :busy}} = SourceSession.prepare(session)

  send(producer_pid, :release_fetch)
  assert_receive {:first_prepare, {:error, {:source, :released}}}
  assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
end
```

Short-lived helper processes are acceptable in these two tests because they model independent protocol callers. Each helper is monitored and asserted down; don't use `Process.sleep/1` or `Process.alive?/1`.

Delete or rewrite the old test named `"abnormal linked exits halt the suspended stream before stopping the session"`. After this refactor, source/encoder helper exits belong to `SourceSession.Producer`, not `SourceSession`. Replace that coverage with producer-level error tests and keep SourceSession tests focused on producer `:DOWN`, owner death, parent shutdown, cancel, and cache cleanup.

Update the existing parent-shutdown coverage in `test/image_plug/request/source_session_supervisor_test.exs` so a shutdown during active `prepare/1` also monitors the producer/fetch process and proves it exits. That test should still assert the pending prepare caller receives `{:error, {:session, {:shutdown, :shutdown}}}`.

- [ ] **Step 2: Run SourceSession tests and verify failure**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs
```

Expected: FAIL. The current `SourceSession.next/1` can't reply before the blocked continuation yields.

- [ ] **Step 3: Change SourceSession state to track producer and pending calls**

In `lib/image_plug/request/source_session.ex`, replace stream-owned fields and processor aliases.

Remove these aliases from `SourceSession`:

```elixir
alias ImagePlug.Output.Encoder
alias ImagePlug.Output.Policy
alias ImagePlug.Output.Resolved
alias ImagePlug.Request.Processor
alias ImagePlug.Request.Processor.Decoded
alias ImagePlug.Source.StreamError
alias ImagePlug.Transform.State
```

Add:

```elixir
alias ImagePlug.Request.SourceSession.Producer
```

Change the struct to:

```elixir
defstruct [
  :request,
  :owner,
  :owner_monitor,
  :parent,
  :producer,
  :producer_monitor,
  :producer_request_ref,
  :pending,
  :resolved_output,
  :cache_sink,
  phase: :new
]
```

The `:pending` field should be one of:

```elixir
nil
| {:prepare, GenServer.from()}
| {:next, GenServer.from()}
| {:cancel, GenServer.from()}
```

The implementation must never overwrite a non-nil pending caller. Add catch-all guards before phase-specific protocol work:

```elixir
def handle_call(message, _from, %{pending: {_kind, _pending_from}} = state)
    when message in [:prepare, :next] do
  {:reply, {:error, {:protocol, :busy}}, state}
end
```

Place this clause before the normal `:prepare` and `:next` clauses. `cancel/1` is different: it must resolve any pending caller before stopping the session.

- [ ] **Step 4: Make prepare/1 asynchronous inside the GenServer**

Replace `handle_call(:prepare, ...)` with a `{:noreply, state}` flow:

```elixir
def handle_call(:prepare, from, %{phase: :new} = state) do
  case start_producer(state) do
    {:ok, state} ->
      ref = Producer.request_next(state.producer, self())

      {:noreply,
       %{state | phase: :preparing, pending: {:prepare, from}, producer_request_ref: ref}}

    {:error, reason} ->
      {:stop, :normal, {:error, reason}, mark_failed(state)}
  end
end
```

Add:

```elixir
defp start_producer(%{request: %Request{} = request} = state) do
  caller_chain = Process.get(:"$callers", [])
  {:ok, producer} = Producer.start_link(request, caller_chain: caller_chain)
  ref = Process.monitor(producer)
  {:ok, %{state | producer: producer, producer_monitor: ref}}
end

```

Don't use `Producer.next/2` from inside `SourceSession`; that helper waits for a reply and would reintroduce blocking inside the session GenServer. Use `Producer.request_next/2`, store the returned ref, and handle the reply in `handle_info/2`.

- [ ] **Step 5: Make next/1 asynchronous inside the GenServer**

Replace `handle_call(:next, ...)` with:

```elixir
def handle_call(:next, from, %{phase: phase, producer: producer, pending: nil} = state)
    when phase in [:prepared, :streaming] and is_pid(producer) do
  ref = Producer.request_next(producer, self())
  {:noreply, %{state | phase: :streaming, pending: {:next, from}, producer_request_ref: ref}}
end
```

Keep invalid protocol calls tagged:

```elixir
def handle_call(:next, _from, state) do
  {:reply, {:error, {:protocol, :not_prepared}}, state}
end
```

- [ ] **Step 6: Handle producer replies**

Add `handle_info/2` clauses for producer replies.

Use this message shape:

```elixir
{ref, {:ok, {:first_chunk, chunk, content_type, headers, resolved_output}}}
{ref, {:ok, {:chunk, chunk}}}
{ref, {:ok, :done}}
{ref, {:error, reason}}
```

If the implementation uses a different internal ref shape, keep it private but preserve the same outcomes.

Add helper functions:

```elixir
def handle_info({ref, result}, %{producer_request_ref: ref} = state) when is_reference(ref) do
  handle_producer_result(result, %{state | producer_request_ref: nil})
end

defp handle_producer_result(
       {:ok, {:first_chunk, first_chunk, content_type, headers, resolved_output}},
       %{pending: {:prepare, from}, request: request} = state
     ) do
  with_owner_check(state, fn state ->
    cache_sink = Cache.open_sink(request.cache_key, resolved_output, request.opts)
    cache_sink = Cache.write_chunk(cache_sink, first_chunk, request.opts)

    prepared = %Prepared{
      first_chunk: first_chunk,
      content_type: content_type,
      headers: headers,
      resolved_output: resolved_output
    }

    GenServer.reply(from, {:ok, prepared})

    {:noreply,
     %{
       state
       | pending: nil,
         phase: :prepared,
         cache_sink: cache_sink,
         resolved_output: resolved_output
     }}
  end)
end

defp handle_producer_result({:ok, {:chunk, chunk}}, %{pending: {:next, from}} = state) do
  with_owner_check(state, fn state ->
    cache_sink = Cache.write_chunk(state.cache_sink, chunk, state.request.opts)
    GenServer.reply(from, {:chunk, chunk})
    {:noreply, %{state | pending: nil, cache_sink: cache_sink}}
  end)
end

defp handle_producer_result({:ok, :done}, %{pending: {:next, from}} = state) do
  with_owner_check(state, fn state ->
    Cache.commit_sink(state.cache_sink, state.request.opts)
    GenServer.reply(from, :done)
    {:stop, :normal,
     %{
       state
       | phase: :done,
         pending: nil,
         producer: nil,
         producer_monitor: nil,
         producer_request_ref: nil,
         cache_sink: nil
     }}
  end)
end

defp handle_producer_result({:error, reason}, %{pending: {_kind, from}} = state) do
  state = abort_cache_sink(state, :stream_error)
  GenServer.reply(from, {:error, reason})
  {:stop, :normal, mark_failed(%{state | pending: nil, producer_request_ref: nil})}
end
```

`handle_producer_result/2` must distinguish prepare from next for `:empty_stream` and source/decode/output errors only through the existing return shape. Before headers commit, Runner already maps `prepare/1` errors to pre-response errors. After headers commit, Sender already treats `next/1` errors as stream failures.

Add the owner monitor check used above. This is the only selective receive that remains in `SourceSession`; it checks the session owner's monitor just before delivering or committing producer output:

```elixir
defp with_owner_check(state, fun) when is_function(fun, 1) do
  case receive_owner_down_message(state) do
    {:owner_down, reason} ->
      state =
        state
        |> reply_pending({:error, {:session, {:shutdown, {:owner_down, reason}}}})
        |> stop_producer(:shutdown)
        |> abort_cache_sink(:owner_down)

      {:stop, {:shutdown, {:owner_down, reason}}, %{state | phase: :cancelled, pending: nil}}

    :none ->
      fun.(state)
  end
end

defp receive_owner_down_message(%{owner: owner, owner_monitor: ref}) do
  receive do
    {:DOWN, ^ref, :process, ^owner, reason} -> {:owner_down, reason}
  after
    0 -> :none
  end
end
```

- [ ] **Step 7: Handle owner death while a call is pending**

Replace owner `:DOWN` handling with a helper that replies to pending callers before stopping:

```elixir
def handle_info(
      {:DOWN, ref, :process, owner, reason},
      %{owner: owner, owner_monitor: ref} = state
    ) do
  state =
    state
    |> reply_pending({:error, {:session, {:shutdown, {:owner_down, reason}}}})
    |> stop_producer(:shutdown)
    |> abort_cache_sink(:owner_down)

  {:stop, {:shutdown, {:owner_down, reason}}, %{state | phase: :cancelled, pending: nil}}
end
```

Add:

```elixir
defp reply_pending(%{pending: nil} = state, _reply), do: state

defp reply_pending(%{pending: {_kind, from}} = state, reply) do
  GenServer.reply(from, reply)
  %{state | pending: nil, producer_request_ref: nil}
end

defp stop_producer(%{producer: nil} = state, _reason), do: state

defp stop_producer(%{producer: producer} = state, reason) when is_pid(producer) do
  Process.exit(producer, reason)
  if is_reference(state.producer_monitor), do: Process.demonitor(state.producer_monitor, [:flush])
  %{state | producer: nil, producer_monitor: nil, producer_request_ref: nil}
end
```

Keep a controlled parent shutdown path. This replaces the old generic linked-exit handling but preserves supervisor cleanup:

```elixir
def handle_info({:EXIT, parent, reason}, %{parent: parent} = state) when is_pid(parent) do
  state =
    state
    |> reply_pending({:error, {:session, {:shutdown, reason}}})
    |> stop_producer(:shutdown)
    |> abort_cache_sink(:cancelled)

  {:stop, reason, %{state | phase: :cancelled, pending: nil}}
end
```

Parent exit is normalized to `{:error, {:session, {:shutdown, reason}}}` for pending callers, while the session itself exits with the original parent reason. Keep that distinction explicit in tests.

- [ ] **Step 8: Handle producer DOWN**

Add monitor-based producer failure handling. The producer link prevents orphan processes; the producer monitor is the authoritative failure signal. Ignore linked producer exits after parent handling so an abnormal producer death doesn't run cleanup twice.

```elixir
def handle_info(
      {:DOWN, ref, :process, producer, reason},
      %{producer: producer, producer_monitor: ref} = state
    ) do
  case {reason, state.pending} do
    {:normal, nil} ->
      {:noreply, %{state | producer: nil, producer_monitor: nil, producer_request_ref: nil}}

    {:normal, _pending} ->
      state =
        state
        |> reply_pending({:error, {:producer, {:exit, :normal}}})
        |> abort_cache_sink(:stream_error)

      {:stop, :normal,
       mark_failed(%{state | producer: nil, producer_monitor: nil, producer_request_ref: nil})}

    {reason, _pending} ->
      state =
        state
        |> reply_pending({:error, producer_down_reason(reason)})
        |> abort_cache_sink(:stream_error)

      {:stop, :normal,
       mark_failed(%{state | producer: nil, producer_monitor: nil, producer_request_ref: nil})}
  end
end

defp producer_down_reason(reason), do: {:session, {:producer_down, reason}}

def handle_info({:EXIT, _pid, _reason}, state) do
  {:noreply, state}
end
```

`SourceSession` must not alias or pattern-match `ImagePlug.Source.StreamError`. The producer should return normalized `{:error, {:source, reason}}` replies for source stream errors. Unexpected producer death should stay a session-level producer failure.

Remove the old catch-all `handle_info({:EXIT, pid, reason}, ...)` that treats arbitrary linked exits as stream errors. After this refactor, only parent exits are meaningful linked-exit control messages in `SourceSession`. A delayed `{:EXIT, old_producer, :shutdown}` after `stop_producer/2` clears `state.producer` is intentionally ignored by the catch-all above.

- [ ] **Step 9: Rewrite cancel/1 around producer halt**

Replace `handle_call(:cancel, ...)` with:

```elixir
def handle_call(:cancel, _from, %{pending: nil} = state) do
  state =
    state
    |> halt_or_stop_producer()
    |> abort_cache_sink(:cancelled)

  {:stop, :normal, :ok, %{state | phase: :cancelled, pending: nil}}
end

def handle_call(:cancel, _from, %{pending: {_kind, _pending_from}} = state) do
  state =
    state
    |> reply_pending({:error, {:session, :cancelled}})
    |> stop_producer(:shutdown)
    |> abort_cache_sink(:cancelled)

  {:stop, :normal, :ok, %{state | phase: :cancelled, pending: nil}}
end
```

If a stale `{producer_request_ref, result}` message is already in the session mailbox when `cancel/1` stops the session, it's safe to discard. The session is stopping and no caller is pending.

Add:

```elixir
defp halt_or_stop_producer(%{producer: nil} = state), do: state

defp halt_or_stop_producer(%{producer: producer} = state) do
  case Producer.halt(producer, max(100, div(@cancel_timeout, 2))) do
    :ok ->
      if is_reference(state.producer_monitor), do: Process.demonitor(state.producer_monitor, [:flush])
      %{state | producer: nil, producer_monitor: nil, producer_request_ref: nil}

    {:error, _reason} ->
      stop_producer(state, :shutdown)
  end
end
```

- [ ] **Step 10: Remove stream enumeration from SourceSession**

Delete these SourceSession functions after producer integration replaces them:

```elixir
prepare_stream/1
prepare_encoded_stream/3
prepare_first_chunk/4
fetch_decode_validate_source/4
receive_session_control_message/2
resolve_output/3
first_chunk/1
next_chunk/1
continue_stream/3
receive_session_control_after_chunk/1
reduce_stream/1
reduce_result/2
finish_stream/1
halt_stream/1
shutdown_halt_stream/2
cache_shutdown_reason/1
```

Keep or rewrite:

```elixir
abort_cache_sink/2
mark_failed/1
call_session/3
```

Rename any remaining private `call/3` wrapper to `call_session/3`; the public `prepare/2`, `next/2`, and `cancel/2` functions should call that wrapper.

Keep `terminate/2`, but rewrite it so abnormal session termination stops the linked producer and aborts cache staging:

```elixir
def terminate(:normal, _state), do: :ok

def terminate(reason, state) do
  cache_reason =
    case reason do
      {:shutdown, {:owner_down, _reason}} -> :owner_down
      :shutdown -> :cancelled
      {:shutdown, _reason} -> :cancelled
      _reason -> :stream_error
    end

  state
  |> stop_producer(:shutdown)
  |> abort_cache_sink(cache_reason)

  :ok
end
```

`terminate/2` may run after a callback already stopped the producer and aborted the cache sink. That's safe because `stop_producer/2` and `abort_cache_sink/2` are nil-guarded; keep them idempotent.

The resulting `SourceSession` should coordinate producer messages. It shouldn't call `Enumerable.reduce/3`, `Encoder.stream_output/3`, or `Processor.fetch_decode_validate_source_with_source_format/3`.

- [ ] **Step 11: Run focused tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session/producer_test.exs test/image_plug/request/source_session_test.exs test/image_plug/request/source_session_supervisor_test.exs
```

Expected: PASS.

- [ ] **Step 12: Commit SourceSession refactor**

Run:

```bash
mise exec -- git add lib/image_plug/request/source_session.ex test/image_plug/request/source_session_test.exs test/image_plug/request/source_session_supervisor_test.exs
mise exec -- git commit -m "Refactor source session around producer process"
```

## Task 4: Preserve Runner, Sender, Cache, And Real Vix Behavior

Run integration tests and make only targeted fixes if the producer refactor changed existing contracts.

**Files:**
- Modify: `test/image_plug/request/vix_stream_continuation_test.exs`
- Modify only if tests require it: `lib/image_plug/request/runner.ex`
- Modify only if tests require it: `test/image_plug/request_runner_test.exs`
- Modify only if tests require it: `test/image_plug/response_sender_test.exs`
- Modify only if tests require it: `test/image_plug/architecture_boundary_test.exs`

- [ ] **Step 1: Add real Vix cleanup coverage for killed producer**

Extend `test/image_plug/request/vix_stream_continuation_test.exs` or `test/image_plug/request/source_session/producer_test.exs` with one real-Vix test that starts a producer, pulls the first chunk, observes the linked `Vix.TargetPipe` from `Process.info(producer, :links)`, kills the producer, and asserts the observed target pipe exits. If the writer task is observable from target-pipe state, monitor it and assert it exits too.

Keep the test diagnostic and conservative:

```elixir
test "killing producer after first real Vix chunk stops observed target pipe" do
  Process.flag(:trap_exit, true)

  {:ok, producer} = Producer.start_link(real_vix_request())
  producer_ref = Process.monitor(producer)

  assert {:ok, {:first_chunk, first_chunk, "image/jpeg", [], _resolved_output}} =
           Producer.next(producer)

  assert is_binary(first_chunk)
  assert {:ok, target_pipe} = observed_target_pipe(producer)
  target_ref = Process.monitor(target_pipe)

  writer_ref =
    case observed_writer_task(target_pipe) do
      {:ok, writer} -> Process.monitor(writer)
      :not_observed -> nil
    end

  Process.exit(producer, :shutdown)

  assert_receive {:DOWN, ^producer_ref, :process, ^producer, :shutdown}
  assert_receive {:DOWN, ^target_ref, :process, ^target_pipe, _reason}

  if writer_ref do
    assert_receive {:DOWN, ^writer_ref, :process, _writer, _reason}
  end
end
```

Use the helper-discovery style from the existing Slice 1 proof. If `Vix.TargetPipe` can't be observed, mark this refactor blocked rather than relying only on fake stream cleanup callbacks.

- [ ] **Step 2: Run prepared-stream and runner integration tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request_runner_test.exs test/image_plug/response_sender_test.exs test/image_plug/architecture_boundary_test.exs
```

Expected: PASS. If any test fails, adjust only the boundary where the contract changed accidentally. `Response.Sender` shouldn't need changes.

- [ ] **Step 3: Run real Vix continuation and source-session tests together**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/vix_stream_continuation_test.exs test/image_plug/request/source_session/producer_test.exs test/image_plug/request/source_session_test.exs
```

Expected: PASS. The old proof file remains a characterization of Vix. It doesn't need to know about the producer unless a test name/comment claims SourceSession owns the continuation directly.

- [ ] **Step 4: Run compile with warnings as errors**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix compile --warnings-as-errors
```

Expected: PASS.

- [ ] **Step 5: Run full suite**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test
```

Expected: PASS.

- [ ] **Step 6: Commit integration fixes if any**

If Task 4 required changes, commit them:

```bash
mise exec -- git add <changed files>
mise exec -- git commit -m "Preserve prepared stream integration with producer"
```

If no files changed, don't create an empty commit.

## Required Review Checkpoint

After implementation and before final commit/push, run the required parallel subagent review cycle with these focus areas:

- OTP lifecycle and pending-call handling
- Producer protocol and pull-based back-pressure
- Vix/Enumerable cleanup behavior
- Test quality and architecture boundaries

Ask reviewers to check specifically:

- `SourceSession` no longer performs lazy stream enumeration inside `handle_call/3`.
- `SourceSession` can answer owner death while producer demand is blocked.
- Cache commit still happens only after `:done`.
- Cache abort still happens on owner death, cancel, producer error, and client close.
- `Response.Sender` remains cache-unaware and producer-unaware.
- Producer shutdown semantics don't overstate graceful cleanup when a producer is killed mid-continuation.

Apply accepted feedback, then rerun:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session/producer_test.exs test/image_plug/request/source_session_test.exs test/image_plug/request/source_session_supervisor_test.exs test/image_plug/request_runner_test.exs test/image_plug/response_sender_test.exs test/image_plug/architecture_boundary_test.exs
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix compile --warnings-as-errors
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test
```

## Stop Criteria

Stop and ask for design input if any of these happen:

- The producer needs its own application supervisor to be reliable.
- `Response.Sender` needs to know about producer internals.
- Cache commit/abort requires moving cache sink ownership into the producer.
- Owner death while producer is blocked can't be handled without killing producer and that breaks real Vix cleanup against the pinned fork.
- The refactor grows into response protocol redesign instead of SourceSession internals.

## Final Commit And Push

After accepted review feedback and verification:

```bash
mise exec -- git status --short
```

If review feedback left changes after the task-level commits, commit those changes:

```bash
mise exec -- git add .
mise exec -- git commit -m "Tighten source session producer lifecycle"
mise exec -- git push
```

If HTTPS push is needed, use the branch-safe force-with-lease process already used on this branch.
