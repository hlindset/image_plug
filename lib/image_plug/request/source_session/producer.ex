defmodule ImagePlug.Request.SourceSession.Producer do
  @moduledoc false

  alias ImagePlug.Output.Encoder
  alias ImagePlug.Output.Policy
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Request.Processor
  alias ImagePlug.Request.SourceSession.Request
  alias ImagePlug.Source.StreamError
  alias ImagePlug.Telemetry
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

  # SourceSession uses this non-blocking primitive after enforcing single-flight
  # demand. next/2 is only a focused test helper and is non-retryable after timeout.
  @spec request_next(pid(), pid()) :: reference()
  def request_next(pid, receiver) when is_pid(pid) and is_pid(receiver) do
    ref = make_ref()
    send(pid, {:next, receiver, ref})
    ref
  end

  @spec request_halt(pid(), pid()) :: reference()
  def request_halt(pid, receiver) when is_pid(pid) and is_pid(receiver) do
    ref = make_ref()
    send(pid, {:halt, receiver, ref})
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
    ref = request_halt(pid, self())
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
            # the producer exits normally; unexpected death is reported by the
            # SourceSession monitor.
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
    with {:ok, decoded} <-
           Processor.fetch_decode_validate_source_with_source_format(
             request.plan,
             request.resolved_source,
             request.opts
           ),
         {:ok, %State{} = final_state} <-
           Processor.process_decoded_source(decoded, request.plan, request.opts),
         {:ok, %Resolved{} = resolved_output} <-
           resolve_output(
             request.output_policy,
             decoded.source_format,
             final_state.image,
             request.opts
           ),
         {:ok, stream, content_type} <-
           Encoder.stream_output(final_state.image, resolved_output, request.opts),
         {:ok, chunk, stream_state} <- first_chunk(stream) do
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

  defp resolve_output(%Policy{} = policy, source_format, image, opts) do
    Telemetry.span(
      Telemetry.telemetry_opts(opts),
      [:output, :negotiate],
      output_negotiate_metadata(policy),
      fn ->
        result = do_resolve_output(policy, source_format, image)
        {result, output_negotiate_stop_metadata(result)}
      end
    )
  end

  defp do_resolve_output(%Policy{} = policy, source_format, image) do
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

  defp output_negotiate_metadata(%Policy{} = policy) do
    %{output_mode: output_mode(policy)}
  end

  defp output_mode(%Policy{mode: {:explicit, _format}}), do: :explicit
  defp output_mode(%Policy{mode: :source}), do: :automatic
  defp output_mode(%Policy{mode: :best}), do: :best

  defp output_negotiate_stop_metadata({:ok, %Resolved{format: format}}) do
    %{result: :ok, output_format: format}
  end

  defp output_negotiate_stop_metadata({:error, reason}) do
    %{result: :output_error, error: Telemetry.error(reason)}
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
    # The producer owns the raw Enumerable continuation so each demand pulls one
    # encoded chunk without blocking SourceSession's GenServer mailbox.
    result =
      Enumerable.reduce(stream, {:cont, nil}, fn
        chunk, _previous when is_binary(chunk) and byte_size(chunk) > 0 -> {:suspend, chunk}
        _chunk, previous -> {:cont, previous}
      end)

    case result do
      {:suspended, chunk, continuation} when is_binary(chunk) ->
        {:ok, chunk, {chunk, continuation}}

      {:done, _previous} ->
        :empty

      {:halted, _previous} ->
        :empty
    end
  end

  defp reduce_result({:suspended, chunk, continuation}, state) when is_binary(chunk) do
    {:ok, chunk, %{state | stream_state: {chunk, continuation}}}
  end

  defp reduce_result({:done, _previous}, _state), do: :done
  defp reduce_result({:halted, _previous}, _state), do: :done

  defp halt_stream(%__MODULE__{stream_state: nil}), do: :ok

  defp halt_stream(%__MODULE__{stream_state: {acc, continuation}}) do
    continuation.({:halt, acc})
    :ok
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
