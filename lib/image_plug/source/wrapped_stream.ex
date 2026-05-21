defmodule ImagePlug.Source.WrappedStream do
  @moduledoc false

  @enforce_keys [:stream, :max_body_bytes]
  defstruct @enforce_keys ++ [error_receiver: nil]
end

defimpl Enumerable, for: ImagePlug.Source.WrappedStream do
  alias ImagePlug.Source.StreamError

  def reduce(
        %{stream: stream, max_body_bytes: max_body_bytes, error_receiver: error_receiver},
        acc,
        fun
      ) do
    reduce_stream(stream, max_body_bytes, error_receiver, acc, fun)
  end

  def count(_wrapped), do: {:error, __MODULE__}
  def member?(_wrapped, _value), do: {:error, __MODULE__}
  def slice(_wrapped), do: {:error, __MODULE__}

  defp reduce_stream(stream, max_body_bytes, error_receiver, {:cont, acc}, fun) do
    stream
    |> Enumerable.reduce({:cont, {0, acc}}, reducer(max_body_bytes, fun))
    |> unwrap_result(error_receiver, fun)
  rescue
    error in StreamError ->
      handle_stream_error(error_receiver, error, acc, __STACKTRACE__)

    _error ->
      handle_stream_error(
        error_receiver,
        StreamError.exception(reason: :stream_exception),
        acc,
        __STACKTRACE__
      )
  catch
    _kind, _reason ->
      handle_stream_error(
        error_receiver,
        StreamError.exception(reason: :stream_exception),
        acc,
        __STACKTRACE__
      )
  end

  defp reduce_stream(_stream, _max_body_bytes, _error_receiver, {:halt, acc}, _fun),
    do: {:halted, acc}

  defp reduce_stream(stream, max_body_bytes, error_receiver, {:suspend, acc}, fun),
    do: {:suspended, acc, &reduce_stream(stream, max_body_bytes, error_receiver, &1, fun)}

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

  defp unwrap_result({:done, {_size, acc}}, _error_receiver, _fun), do: {:done, acc}
  defp unwrap_result({:halted, {_size, acc}}, _error_receiver, _fun), do: {:halted, acc}

  defp unwrap_result({:suspended, {size, acc}, continuation}, error_receiver, fun) do
    {:suspended, acc, &continue(continuation, size, error_receiver, &1, fun)}
  end

  defp continue(continuation, size, error_receiver, {:cont, acc}, fun) do
    continue_safely(continuation, {:cont, {size, acc}}, error_receiver, acc, fun)
  end

  defp continue(continuation, size, error_receiver, {:halt, acc}, fun) do
    continue_safely(continuation, {:halt, {size, acc}}, error_receiver, acc, fun)
  end

  defp continue(continuation, size, error_receiver, {:suspend, acc}, fun) do
    continue_safely(continuation, {:suspend, {size, acc}}, error_receiver, acc, fun)
  end

  defp continue_safely(continuation, command, error_receiver, acc, fun) do
    continuation.(command)
    |> unwrap_result(error_receiver, fun)
  rescue
    error in StreamError ->
      handle_stream_error(error_receiver, error, acc, __STACKTRACE__)

    _error ->
      handle_stream_error(
        error_receiver,
        StreamError.exception(reason: :stream_exception),
        acc,
        __STACKTRACE__
      )
  catch
    _kind, _reason ->
      handle_stream_error(
        error_receiver,
        StreamError.exception(reason: :stream_exception),
        acc,
        __STACKTRACE__
      )
  end

  defp handle_stream_error(nil, error, _acc, stacktrace), do: reraise(error, stacktrace)

  defp handle_stream_error(receiver, error, _acc, stacktrace) when receiver == self(),
    do: reraise(error, stacktrace)

  defp handle_stream_error(receiver, %StreamError{} = error, acc, _stacktrace) do
    send(receiver, {:source_stream_error, self(), error})
    {:halted, acc}
  end
end
