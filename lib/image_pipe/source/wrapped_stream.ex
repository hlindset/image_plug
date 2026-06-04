defmodule ImagePipe.Source.WrappedStream do
  @moduledoc false

  @enforce_keys [:stream, :max_body_bytes, :stream_state_ref]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          stream: Enumerable.t(),
          max_body_bytes: non_neg_integer() | :infinity,
          stream_state_ref: :atomics.atomics_ref()
        }

  @body_limit_index 1
  @stream_error_index 2
  @stream_error_reasons %{
    stream_exception: 1,
    body_too_large: 2,
    invalid_stream_chunk: 3
  }
  @stream_error_reason_by_code %{
    1 => :stream_exception,
    2 => :body_too_large,
    3 => :invalid_stream_chunk
  }

  @spec new(Enumerable.t(), non_neg_integer() | :infinity) :: t()
  def new(stream, max_body_bytes) do
    %__MODULE__{
      stream: stream,
      max_body_bytes: max_body_bytes,
      stream_state_ref: :atomics.new(2, [])
    }
  end

  @spec body_limit_exceeded?(t()) :: boolean()
  def body_limit_exceeded?(%__MODULE__{stream_state_ref: stream_state_ref}) do
    :atomics.get(stream_state_ref, @body_limit_index) == 1
  end

  @spec mark_body_limit_exceeded(t()) :: :ok
  def mark_body_limit_exceeded(%__MODULE__{stream_state_ref: stream_state_ref}) do
    :atomics.put(stream_state_ref, @body_limit_index, 1)
    :ok
  end

  @spec mark_stream_error(t(), term()) :: :ok
  def mark_stream_error(%__MODULE__{stream_state_ref: stream_state_ref}, reason) do
    :atomics.put(stream_state_ref, @stream_error_index, stream_error_code(reason))
    :ok
  end

  @spec stream_error_reason(t()) :: {:ok, term()} | :error
  def stream_error_reason(%__MODULE__{stream_state_ref: stream_state_ref}) do
    case :atomics.get(stream_state_ref, @stream_error_index) do
      0 -> :error
      code -> {:ok, Map.fetch!(@stream_error_reason_by_code, code)}
    end
  end

  defp stream_error_code(reason), do: Map.get(@stream_error_reasons, reason, 1)
end

defimpl Enumerable, for: ImagePipe.Source.WrappedStream do
  alias ImagePipe.Source.StreamError
  alias ImagePipe.Source.WrappedStream

  def reduce(%WrappedStream{} = wrapped, acc, fun) do
    reduce_stream(wrapped, acc, fun)
  end

  def count(_wrapped), do: {:error, __MODULE__}
  def member?(_wrapped, _value), do: {:error, __MODULE__}
  def slice(_wrapped), do: {:error, __MODULE__}

  defp reduce_stream(%WrappedStream{stream: stream} = wrapped, {:cont, acc}, fun) do
    consumer_failure_ref = make_ref()

    with_stream_guard(wrapped, consumer_failure_ref, fn ->
      stream
      |> Enumerable.reduce({:cont, {0, acc}}, reducer(wrapped, fun, consumer_failure_ref))
      |> unwrap_result(wrapped, fun, consumer_failure_ref)
    end)
  end

  defp reduce_stream(%WrappedStream{}, {:halt, acc}, _fun),
    do: {:halted, acc}

  defp reduce_stream(%WrappedStream{} = wrapped, {:suspend, acc}, fun),
    do: {:suspended, acc, &reduce_stream(wrapped, &1, fun)}

  defp reducer(
         %WrappedStream{max_body_bytes: max_body_bytes} = wrapped,
         fun,
         consumer_failure_ref
       ) do
    fn chunk, {size, acc} ->
      with {:ok, binary} <- validate_chunk(chunk),
           {:ok, new_size} <- add_size(size, binary, max_body_bytes) do
        advance_consumer(fun, binary, acc, new_size, consumer_failure_ref)
      else
        {:error, :body_too_large} ->
          WrappedStream.mark_body_limit_exceeded(wrapped)
          WrappedStream.mark_stream_error(wrapped, :body_too_large)
          raise StreamError, reason: :body_too_large

        {:error, reason} ->
          WrappedStream.mark_stream_error(wrapped, reason)
          raise StreamError, reason: reason
      end
    end
  end

  defp advance_consumer(fun, binary, acc, new_size, consumer_failure_ref) do
    case call_consumer(fun, binary, acc, consumer_failure_ref) do
      {:cont, acc} -> {:cont, {new_size, acc}}
      {:halt, acc} -> {:halt, {new_size, acc}}
      {:suspend, acc} -> {:suspend, {new_size, acc}}
    end
  end

  defp call_consumer(fun, binary, acc, consumer_failure_ref) do
    case fun.(binary, acc) do
      {:cont, _acc} = result -> result
      {:halt, _acc} = result -> result
      {:suspend, _acc} = result -> result
      invalid -> raise CaseClauseError, term: invalid
    end
  rescue
    exception ->
      throw({consumer_failure_ref, :error, exception, __STACKTRACE__})
  catch
    kind, reason ->
      throw({consumer_failure_ref, kind, reason, __STACKTRACE__})
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

  defp unwrap_result({:done, {_size, acc}}, _wrapped, _fun, _consumer_failure_ref),
    do: {:done, acc}

  defp unwrap_result({:halted, {_size, acc}}, _wrapped, _fun, _consumer_failure_ref),
    do: {:halted, acc}

  defp unwrap_result({:suspended, {size, acc}, continuation}, wrapped, fun, consumer_failure_ref) do
    {:suspended, acc, &continue(wrapped, continuation, size, &1, fun, consumer_failure_ref)}
  end

  defp continue(wrapped, continuation, size, {:cont, acc}, fun, consumer_failure_ref) do
    continue_safely(wrapped, continuation, {:cont, {size, acc}}, fun, consumer_failure_ref)
  end

  defp continue(wrapped, continuation, size, {:halt, acc}, fun, consumer_failure_ref) do
    continue_safely(wrapped, continuation, {:halt, {size, acc}}, fun, consumer_failure_ref)
  end

  defp continue(wrapped, continuation, size, {:suspend, acc}, fun, consumer_failure_ref) do
    continue_safely(wrapped, continuation, {:suspend, {size, acc}}, fun, consumer_failure_ref)
  end

  defp continue_safely(wrapped, continuation, command, fun, consumer_failure_ref) do
    with_stream_guard(wrapped, consumer_failure_ref, fn ->
      continuation.(command)
      |> unwrap_result(wrapped, fun, consumer_failure_ref)
    end)
  end

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
end
