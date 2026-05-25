defmodule ImagePipe.Source.WrappedStream do
  @moduledoc false

  @enforce_keys [:stream, :max_body_bytes]
  defstruct @enforce_keys
end

defimpl Enumerable, for: ImagePipe.Source.WrappedStream do
  alias ImagePipe.Source.StreamError

  def reduce(%{stream: stream, max_body_bytes: max_body_bytes}, acc, fun) do
    reduce_stream(stream, max_body_bytes, acc, fun)
  end

  def count(_wrapped), do: {:error, __MODULE__}
  def member?(_wrapped, _value), do: {:error, __MODULE__}
  def slice(_wrapped), do: {:error, __MODULE__}

  defp reduce_stream(stream, max_body_bytes, {:cont, acc}, fun) do
    consumer_failure_ref = make_ref()

    try do
      stream
      |> Enumerable.reduce({:cont, {0, acc}}, reducer(max_body_bytes, fun, consumer_failure_ref))
      |> unwrap_result(fun, consumer_failure_ref)
    rescue
      error in StreamError ->
        reraise error, __STACKTRACE__

      _error ->
        raise StreamError, reason: :stream_exception
    catch
      {^consumer_failure_ref, kind, reason, stacktrace} ->
        :erlang.raise(kind, reason, stacktrace)

      _kind, _reason ->
        raise StreamError, reason: :stream_exception
    end
  end

  defp reduce_stream(_stream, _max_body_bytes, {:halt, acc}, _fun),
    do: {:halted, acc}

  defp reduce_stream(stream, max_body_bytes, {:suspend, acc}, fun),
    do: {:suspended, acc, &reduce_stream(stream, max_body_bytes, &1, fun)}

  defp reducer(max_body_bytes, fun, consumer_failure_ref) do
    fn chunk, {size, acc} ->
      with {:ok, binary} <- validate_chunk(chunk),
           {:ok, new_size} <- add_size(size, binary, max_body_bytes) do
        case call_consumer(fun, binary, acc, consumer_failure_ref) do
          {:cont, acc} -> {:cont, {new_size, acc}}
          {:halt, acc} -> {:halt, {new_size, acc}}
          {:suspend, acc} -> {:suspend, {new_size, acc}}
        end
      else
        {:error, reason} -> raise StreamError, reason: reason
      end
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

  defp unwrap_result({:done, {_size, acc}}, _fun, _consumer_failure_ref), do: {:done, acc}
  defp unwrap_result({:halted, {_size, acc}}, _fun, _consumer_failure_ref), do: {:halted, acc}

  defp unwrap_result({:suspended, {size, acc}, continuation}, fun, consumer_failure_ref) do
    {:suspended, acc, &continue(continuation, size, &1, fun, consumer_failure_ref)}
  end

  defp continue(continuation, size, {:cont, acc}, fun, consumer_failure_ref) do
    continue_safely(continuation, {:cont, {size, acc}}, fun, consumer_failure_ref)
  end

  defp continue(continuation, size, {:halt, acc}, fun, consumer_failure_ref) do
    continue_safely(continuation, {:halt, {size, acc}}, fun, consumer_failure_ref)
  end

  defp continue(continuation, size, {:suspend, acc}, fun, consumer_failure_ref) do
    continue_safely(continuation, {:suspend, {size, acc}}, fun, consumer_failure_ref)
  end

  defp continue_safely(continuation, command, fun, consumer_failure_ref) do
    try do
      continuation.(command)
      |> unwrap_result(fun, consumer_failure_ref)
    rescue
      error in StreamError ->
        reraise error, __STACKTRACE__

      _error ->
        raise StreamError, reason: :stream_exception
    catch
      {^consumer_failure_ref, kind, reason, stacktrace} ->
        :erlang.raise(kind, reason, stacktrace)

      _kind, _reason ->
        raise StreamError, reason: :stream_exception
    end
  end
end
