defmodule ImagePlug.Request.SourceSession do
  @moduledoc false

  use GenServer

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
    :suspended,
    :resolved_output,
    phase: :new,
    first_error: nil,
    exits: []
  ]

  @type server() :: GenServer.server()

  @spec start(Request.t(), keyword()) :: GenServer.on_start()
  def start(%Request{} = request, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    parent = Keyword.get(opts, :parent)

    GenServer.start(__MODULE__, {request, owner, parent})
  end

  @spec start_link(Request.t(), keyword()) :: GenServer.on_start()
  def start_link(%Request{} = request, opts \\ []) do
    owner = Keyword.get(opts, :owner, self())
    parent = Keyword.get(opts, :parent, self())

    GenServer.start_link(__MODULE__, {request, owner, parent})
  end

  @spec child_spec({Request.t(), keyword()}) :: Supervisor.child_spec()
  def child_spec({%Request{} = request, opts}) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [request, opts]},
      restart: :temporary,
      shutdown: @shutdown_timeout,
      type: :worker,
      modules: [__MODULE__]
    }
  end

  @spec prepare(server(), timeout()) :: {:ok, Prepared.t()} | {:error, term()}
  def prepare(server, timeout \\ @call_timeout), do: call(server, :prepare, timeout)

  @spec next(server(), timeout()) :: {:chunk, binary()} | :done | {:error, term()}
  def next(server, timeout \\ @call_timeout), do: call(server, :next, timeout)

  @spec cancel(server(), timeout()) :: :ok | {:error, term()}
  def cancel(server, timeout \\ @cancel_timeout), do: call(server, :cancel, timeout)

  @impl GenServer
  def init({%Request{} = request, owner, parent}) when is_pid(owner) do
    Process.flag(:trap_exit, true)
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
        {:stop, reason, state}

      {:error, reason, state} ->
        {:stop, :normal, {:error, reason}, mark_failed(state, reason)}
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
        {:stop, :normal, {:error, reason}, mark_failed(state, reason)}
    end
  end

  def handle_call(:next, _from, state) do
    {:reply, {:error, {:protocol, :not_prepared}}, state}
  end

  def handle_call(:cancel, _from, state) do
    case halt_stream(%{state | phase: :cancelled}) do
      {:ok, state} ->
        {:stop, :normal, :ok, state}

      {:error, reason, state} ->
        {:stop, {:shutdown, {:cancel_failed, reason}}, {:error, {:cancel, reason}}, state}
    end
  end

  @impl GenServer
  def handle_info(
        {:DOWN, ref, :process, owner, reason},
        %{owner: owner, owner_monitor: ref} = state
      ) do
    state = shutdown_halt_stream(%{state | phase: :cancelled})
    {:stop, {:shutdown, {:owner_down, reason}}, state}
  end

  def handle_info({:EXIT, pid, :normal}, state) do
    {:noreply, %{state | exits: [{pid, :normal} | state.exits]}}
  end

  def handle_info({:EXIT, parent, :shutdown}, %{parent: parent} = state) do
    state = shutdown_halt_stream(%{state | phase: :cancelled})
    {:stop, :shutdown, state}
  end

  def handle_info({:EXIT, parent, {:shutdown, _reason} = shutdown}, %{parent: parent} = state) do
    state = shutdown_halt_stream(%{state | phase: :cancelled})
    {:stop, shutdown, state}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    reason = {:linked_exit, pid, reason}

    state =
      state
      |> Map.update!(:exits, &[{pid, reason} | &1])
      |> shutdown_halt_stream()
      |> mark_failed(reason)

    {:stop, reason, state}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(:shutdown, state) do
    _state = shutdown_halt_stream(%{state | phase: :cancelled})
    :ok
  end

  def terminate({:shutdown, _reason}, state) do
    _state = shutdown_halt_stream(%{state | phase: :cancelled})
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp call(server, message, timeout) do
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
             state.parent
           ),
         {:ok, %State{} = final_state} <-
           Processor.process_decoded_source(decoded, request.plan, request.opts),
         {:ok, %Resolved{} = resolved_output} <-
           resolve_output(request.output_policy, decoded.source_format, final_state.image),
         {:ok, stream, content_type} <-
           Encoder.stream_output(final_state.image, resolved_output, request.opts),
         {:ok, first_chunk, suspended} <- first_chunk(stream) do
      state = %{state | suspended: suspended, resolved_output: resolved_output}

      case receive_linked_exit(:ok, state.parent) do
        :ok ->
          prepared = %Prepared{
            first_chunk: first_chunk,
            content_type: content_type,
            headers: resolved_output.response_headers,
            resolved_output: resolved_output
          }

          {:ok, prepared, state}

        {:error, reason} ->
          {:error, reason, shutdown_halt_stream(state)}

        {:shutdown, reason} ->
          {:shutdown, reason, shutdown_halt_stream(state)}
      end
    else
      {:shutdown, reason} ->
        {:shutdown, reason, shutdown_halt_stream(state)}

      {:error, reason} ->
        {:error, reason, shutdown_halt_stream(state)}

      :empty ->
        {:error, {:encode, RuntimeError.exception("image encoder produced an empty stream"), []},
         state}
    end
  catch
    kind, reason -> {:error, {kind, reason}, shutdown_halt_stream(state)}
  end

  defp fetch_decode_validate_source(plan, resolved_source, opts, parent) do
    plan
    |> Processor.fetch_decode_validate_source_with_source_format(resolved_source, opts)
    |> receive_linked_exit(parent)
  end

  defp receive_linked_exit(result, parent) do
    receive do
      {:EXIT, pid, :shutdown} when is_pid(parent) and pid == parent ->
        {:shutdown, :shutdown}

      {:EXIT, pid, {:shutdown, _reason} = shutdown} when is_pid(parent) and pid == parent ->
        {:shutdown, shutdown}

      {:EXIT, _pid, {%StreamError{reason: reason}, _stacktrace}} ->
        {:error, {:source, reason}}

      {:EXIT, _pid, %StreamError{reason: reason}} ->
        {:error, {:source, reason}}

      {:EXIT, _pid, :normal} ->
        receive_linked_exit(result, parent)

      {:EXIT, pid, reason} when pid != parent ->
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

  defp next_chunk(%{suspended: {acc, continuation}} = state) do
    continuation.({:cont, acc})
    |> reduce_result(%{state | suspended: nil})
  rescue
    exception in [StreamError] ->
      {{:error, {:source, exception.reason}}, %{state | suspended: nil}}

    exception ->
      {{:error, {:encode, exception, __STACKTRACE__}}, %{state | suspended: nil}}
  catch
    :exit, {%StreamError{reason: reason}, _stacktrace} ->
      {{:error, {:source, reason}}, %{state | suspended: nil}}

    :exit, %StreamError{reason: reason} ->
      {{:error, {:source, reason}}, %{state | suspended: nil}}

    kind, reason ->
      {{:error, {:encode, {kind, reason}, []}}, %{state | suspended: nil}}
  end

  defp next_chunk(%{suspended: nil} = state), do: {:done, state}

  defp reduce_stream(stream) do
    stream
    |> Enumerable.reduce({:cont, nil}, fn
      chunk, _acc when is_binary(chunk) and byte_size(chunk) > 0 -> {:suspend, chunk}
      _chunk, acc -> {:cont, acc}
    end)
    |> case do
      {:suspended, chunk, continuation} when is_binary(chunk) ->
        {:ok, chunk, {chunk, continuation}}

      {:done, _acc} ->
        :empty

      {:halted, _acc} ->
        :empty
    end
  end

  defp reduce_result({:suspended, chunk, continuation}, state) when is_binary(chunk) do
    {{:chunk, chunk}, %{state | suspended: {chunk, continuation}}}
  end

  defp reduce_result({:done, _acc}, state), do: {:done, %{state | suspended: nil}}
  defp reduce_result({:halted, _acc}, state), do: {:done, %{state | suspended: nil}}

  defp halt_stream(%{suspended: nil} = state), do: {:ok, state}

  defp halt_stream(%{suspended: {acc, continuation}} = state) do
    _result = continuation.({:halt, acc})
    {:ok, %{state | suspended: nil}}
  catch
    kind, reason -> {:error, {kind, reason}, %{state | suspended: nil}}
  end

  defp shutdown_halt_stream(state) do
    case halt_stream(state) do
      {:ok, state} -> state
      {:error, reason, state} -> mark_failed(state, {:cancel, reason})
    end
  end

  defp mark_failed(state, reason), do: %{state | phase: :failed, first_error: reason}
end
