defmodule ImagePlug.Request.SourceSession do
  @moduledoc false

  use GenServer

  alias ImagePlug.Cache
  alias ImagePlug.Output.Encoder
  alias ImagePlug.Output.Policy
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Request.Processor
  alias ImagePlug.Request.Processor.Decoded
  alias ImagePlug.Request.SourceSession.Prepared
  alias ImagePlug.Request.SourceSession.Request
  alias ImagePlug.Source.StreamError
  alias ImagePlug.Transform.State

  @call_timeout 15_000
  @cancel_timeout 2_000
  @shutdown_timeout 2_000

  defstruct [
    :request,
    :owner,
    :owner_monitor,
    :parent,
    :stream_state,
    :resolved_output,
    :cache_sink,
    phase: :new
  ]

  @type server() :: GenServer.server()

  @spec start(Request.t(), keyword()) :: GenServer.on_start()
  def start(%Request{} = request, opts \\ []) do
    start_server(:start, request, opts, nil)
  end

  @spec start_link(Request.t(), keyword()) :: GenServer.on_start()
  def start_link(%Request{} = request, opts \\ []) do
    start_server(:start_link, request, opts, self())
  end

  @spec child_spec({Request.t(), keyword()}) :: Supervisor.child_spec()
  def child_spec({%Request{} = request, opts}) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [request, opts]},
      restart: :temporary,
      shutdown: @shutdown_timeout,
      type: :worker,
      modules: [__MODULE__]
    }
  end

  @spec prepare(server(), timeout()) :: {:ok, Prepared.t()} | {:error, term()}
  def prepare(server, timeout \\ @call_timeout), do: call_session(server, :prepare, timeout)

  @spec next(server(), timeout()) :: {:chunk, binary()} | :done | {:error, term()}
  def next(server, timeout \\ @call_timeout), do: call_session(server, :next, timeout)

  @spec cancel(server(), timeout()) :: :ok | {:error, term()}
  def cancel(server, timeout \\ @cancel_timeout), do: call_session(server, :cancel, timeout)

  defp start_server(kind, %Request{} = request, opts, default_parent) do
    owner = Keyword.get(opts, :owner, self())
    parent = Keyword.get(opts, :parent, default_parent)

    case kind do
      :start -> GenServer.start(__MODULE__, {request, owner, parent})
      :start_link -> GenServer.start_link(__MODULE__, {request, owner, parent})
    end
  end

  @impl GenServer
  def init({%Request{} = request, owner, parent}) when is_pid(owner) do
    Process.flag(:trap_exit, true)
    # Preserve request ownership for Tasks spawned by downstream image/source code.
    Process.put(:"$callers", [owner | Process.get(:"$callers", [])])

    {:ok,
     %__MODULE__{
       request: request,
       owner: owner,
       owner_monitor: Process.monitor(owner),
       parent: parent
     }}
  end

  @impl GenServer
  def handle_call(:prepare, _from, %{phase: :new} = state) do
    case prepare_stream(%{state | phase: :preparing}) do
      {:ok, %Prepared{} = prepared, state} ->
        {:reply, {:ok, prepared}, %{state | phase: :prepared}}

      {:shutdown, reason, state} ->
        stop_reason =
          case reason do
            {:owner_down, _reason} = owner_down -> {:shutdown, owner_down}
            reason -> reason
          end

        {:stop, stop_reason, {:error, {:session, {:shutdown, reason}}}, state}

      {:error, reason, state} ->
        {:stop, :normal, {:error, reason}, mark_failed(state)}
    end
  end

  def handle_call(:prepare, _from, state) do
    {:reply, {:error, {:protocol, {:invalid_phase, state.phase}}}, state}
  end

  def handle_call(:next, _from, %{phase: phase} = state) when phase in [:prepared, :streaming] do
    case next_chunk(%{state | phase: :streaming}) do
      {{:chunk, chunk}, state} ->
        {:reply, {:chunk, chunk}, state}

      {:done, state} ->
        {:stop, :normal, :done, %{state | phase: :done}}

      {{:error, reason}, state} ->
        {:stop, :normal, {:error, reason}, mark_failed(state)}
    end
  end

  def handle_call(:next, _from, state) do
    {:reply, {:error, {:protocol, :not_prepared}}, state}
  end

  def handle_call(:cancel, _from, state) do
    case halt_stream(%{state | phase: :cancelled}) do
      {:ok, state} ->
        state = abort_cache_sink(state, :cancelled)
        {:stop, :normal, :ok, state}

      {:error, reason, state} ->
        state = abort_cache_sink(state, :cancelled)
        {:stop, {:shutdown, {:cancel_failed, reason}}, {:error, {:cancel, reason}}, state}
    end
  end

  @impl GenServer
  def handle_info(
        {:DOWN, ref, :process, owner, reason},
        %{owner: owner, owner_monitor: ref} = state
      ) do
    state = shutdown_halt_stream(%{state | phase: :cancelled}, :owner_down)
    {:stop, {:shutdown, {:owner_down, reason}}, state}
  end

  def handle_info({:EXIT, parent, reason}, %{parent: parent} = state) when is_pid(parent) do
    state = shutdown_halt_stream(%{state | phase: :cancelled}, :cancelled)

    {:stop, reason, state}
  end

  def handle_info({:EXIT, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    reason = {:linked_exit, pid, reason}

    state =
      state
      |> shutdown_halt_stream(:stream_error)
      |> mark_failed()

    {:stop, reason, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(:shutdown, state) do
    shutdown_halt_stream(%{state | phase: :cancelled}, :cancelled)
    :ok
  end

  def terminate({:shutdown, _reason}, state) do
    shutdown_halt_stream(%{state | phase: :cancelled}, :cancelled)
    :ok
  end

  def terminate(:normal, _state), do: :ok

  def terminate(_reason, state) do
    shutdown_halt_stream(%{state | phase: :cancelled}, :stream_error)
    :ok
  end

  defp call_session(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, {:session, :timeout}}
    :exit, {:noproc, _call} -> {:error, {:session, :noproc}}
    :exit, {{:shutdown, reason}, _call} -> {:error, {:session, {:shutdown, reason}}}
    :exit, {reason, _call} -> {:error, {:session, {:exit, reason}}}
    :exit, reason -> {:error, {:session, {:exit, reason}}}
  end

  defp prepare_stream(%{request: %Request{} = request} = state) do
    with {:ok, %Decoded{} = decoded} <-
           fetch_decode_validate_source(
             request.plan,
             request.resolved_source,
             request.opts,
             state
           ),
         {:ok, %State{} = final_state} <-
           Processor.process_decoded_source(decoded, request.plan, request.opts),
         {:ok, %Resolved{} = resolved_output} <-
           resolve_output(request.output_policy, decoded.source_format, final_state.image) do
      prepare_encoded_stream(state, final_state.image, resolved_output)
    else
      {:shutdown, reason} ->
        {:shutdown, reason, shutdown_halt_stream(state, cache_shutdown_reason(reason))}

      {:error, reason} ->
        {:error, reason, shutdown_halt_stream(state, :stream_error)}

      :empty ->
        {:error, {:encode, :empty_stream}, state}
    end
  catch
    kind, reason ->
      {:error, {:encode, {kind, reason}, []}, shutdown_halt_stream(state, :stream_error)}
  end

  defp prepare_encoded_stream(%{request: %Request{} = request} = state, image, resolved_output) do
    cache_sink = Cache.open_sink(request.cache_key, resolved_output, request.opts)
    state = %{state | cache_sink: cache_sink, resolved_output: resolved_output}

    with {:ok, stream, content_type} <-
           Encoder.stream_output(image, resolved_output, request.opts),
         {:ok, first_chunk, stream_state} <- first_chunk(stream) do
      state = %{state | stream_state: stream_state}
      prepare_first_chunk(state, first_chunk, content_type, resolved_output)
    else
      {:error, reason} ->
        {:error, reason, shutdown_halt_stream(state, :stream_error)}

      :empty ->
        {:error, {:encode, :empty_stream}, abort_cache_sink(state, :stream_error)}
    end
  catch
    kind, reason ->
      {:error, {:encode, {kind, reason}, []}, shutdown_halt_stream(state, :stream_error)}
  end

  defp prepare_first_chunk(
         %{request: %Request{} = request} = state,
         first_chunk,
         content_type,
         resolved_output
       ) do
    cache_sink = Cache.write_chunk(state.cache_sink, first_chunk, request.opts)
    state = %{state | cache_sink: cache_sink}

    case receive_session_control_message(:ok, state) do
      :ok ->
        prepared = %Prepared{
          first_chunk: first_chunk,
          content_type: content_type,
          headers: resolved_output.response_headers,
          resolved_output: resolved_output
        }

        {:ok, prepared, state}

      {:error, reason} ->
        {:error, reason, shutdown_halt_stream(state, :stream_error)}

      {:shutdown, reason} ->
        {:shutdown, reason, shutdown_halt_stream(state, cache_shutdown_reason(reason))}
    end
  catch
    kind, reason ->
      {:error, {:encode, {kind, reason}, []}, shutdown_halt_stream(state, :stream_error)}
  end

  defp fetch_decode_validate_source(plan, resolved_source, opts, state) do
    plan
    |> Processor.fetch_decode_validate_source_with_source_format(resolved_source, opts)
    |> receive_session_control_message(state)
  end

  defp receive_session_control_message(
         result,
         %{owner: owner, owner_monitor: ref, parent: parent} = state
       ) do
    receive do
      {:DOWN, ^ref, :process, ^owner, reason} ->
        {:shutdown, {:owner_down, reason}}

      {:EXIT, ^parent, reason} when is_pid(parent) ->
        {:shutdown, reason}

      {:EXIT, _pid, {%StreamError{reason: reason}, _stacktrace}} ->
        {:error, {:source, reason}}

      {:EXIT, _pid, %StreamError{reason: reason}} ->
        {:error, {:source, reason}}

      {:EXIT, _pid, :normal} ->
        receive_session_control_message(result, state)

      {:EXIT, pid, reason} ->
        {:error, {:linked_exit, pid, reason}}
    after
      0 -> result
    end
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

  defp first_chunk(stream) do
    reduce_stream(stream)
  rescue
    exception in [StreamError] -> {:error, {:source, exception.reason}}
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  catch
    :exit, {%StreamError{reason: reason}, _stacktrace} -> {:error, {:source, reason}}
    :exit, %StreamError{reason: reason} -> {:error, {:source, reason}}
    kind, reason -> {:error, {:encode, {kind, reason}, []}}
  end

  defp next_chunk(%{stream_state: {acc, continuation}} = state) do
    with :ok <- receive_session_control_message(:ok, state) do
      continue_stream(acc, continuation, state)
    else
      {:error, reason} ->
        {{:error, reason}, shutdown_halt_stream(state, :stream_error)}

      {:shutdown, shutdown_reason} ->
        reason = {:session, {:shutdown, shutdown_reason}}

        {{:error, reason}, shutdown_halt_stream(state, cache_shutdown_reason(shutdown_reason))}
    end
  end

  defp next_chunk(%{stream_state: nil} = state), do: {:done, state}

  defp continue_stream(acc, continuation, state) do
    continuation.({:cont, acc})
    |> reduce_result(%{state | stream_state: nil})
    |> receive_session_control_after_chunk()
  rescue
    exception in [StreamError] ->
      {{:error, {:source, exception.reason}},
       abort_cache_sink(%{state | stream_state: nil}, :stream_error)}

    exception ->
      {{:error, {:encode, exception, __STACKTRACE__}},
       abort_cache_sink(%{state | stream_state: nil}, :stream_error)}
  catch
    :exit, {%StreamError{reason: reason}, _stacktrace} ->
      {{:error, {:source, reason}}, abort_cache_sink(%{state | stream_state: nil}, :stream_error)}

    :exit, %StreamError{reason: reason} ->
      {{:error, {:source, reason}}, abort_cache_sink(%{state | stream_state: nil}, :stream_error)}

    kind, reason ->
      {{:error, {:encode, {kind, reason}, []}},
       abort_cache_sink(%{state | stream_state: nil}, :stream_error)}
  end

  defp receive_session_control_after_chunk({{:chunk, _chunk}, state} = result) do
    case receive_session_control_message(:ok, state) do
      :ok ->
        result

      {:error, reason} ->
        {{:error, reason}, shutdown_halt_stream(state, :stream_error)}

      {:shutdown, shutdown_reason} ->
        reason = {:session, {:shutdown, shutdown_reason}}

        {{:error, reason}, shutdown_halt_stream(state, cache_shutdown_reason(shutdown_reason))}
    end
  end

  defp receive_session_control_after_chunk(result), do: result

  defp reduce_stream(stream) do
    # Store the real Enumerable continuation so each next/1 call pulls exactly
    # one encoded chunk while SourceSession still owns the lazy stream state.
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
    cache_sink = Cache.write_chunk(state.cache_sink, chunk, state.request.opts)

    {{:chunk, chunk}, %{state | stream_state: {chunk, continuation}, cache_sink: cache_sink}}
  end

  defp reduce_result({:done, _acc}, state), do: finish_stream(state)

  # Vix write_to_stream/3 returns {:halt, pipe} from Stream.resource/3 on EOF,
  # so normal completion reaches Enumerable.reduce/3 as {:halted, acc}.
  defp reduce_result({:halted, _acc}, state), do: finish_stream(state)

  defp finish_stream(state) do
    case receive_session_control_message(:ok, state) do
      :ok ->
        Cache.commit_sink(state.cache_sink, state.request.opts)
        {:done, %{state | stream_state: nil, cache_sink: nil}}

      {:error, reason} ->
        {{:error, reason}, abort_cache_sink(%{state | stream_state: nil}, :stream_error)}

      {:shutdown, shutdown_reason} ->
        reason = {:session, {:shutdown, shutdown_reason}}

        {{:error, reason},
         abort_cache_sink(%{state | stream_state: nil}, cache_shutdown_reason(shutdown_reason))}
    end
  end

  defp halt_stream(%{stream_state: nil} = state), do: {:ok, state}

  defp halt_stream(%{stream_state: {acc, continuation}} = state) do
    continuation.({:halt, acc})
    {:ok, %{state | stream_state: nil}}
  catch
    kind, reason -> {:error, {kind, reason}, %{state | stream_state: nil}}
  end

  defp shutdown_halt_stream(state, reason) do
    case halt_stream(state) do
      {:ok, state} ->
        abort_cache_sink(state, reason)

      {:error, _cancel_reason, state} ->
        state
        |> abort_cache_sink(reason)
        |> mark_failed()
    end
  end

  defp abort_cache_sink(%{cache_sink: cache_sink, request: request} = state, reason) do
    Cache.abort_sink(cache_sink, reason, request.opts)
    %{state | cache_sink: nil}
  end

  defp cache_shutdown_reason({:owner_down, _reason}), do: :owner_down
  defp cache_shutdown_reason(_reason), do: :cancelled

  defp mark_failed(state), do: %{state | phase: :failed}
end
