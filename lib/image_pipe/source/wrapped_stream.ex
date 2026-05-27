defmodule ImagePipe.Source.WrappedStream do
  @moduledoc false

  @enforce_keys [:stream, :max_body_bytes, :body_limit_ref]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          stream: Enumerable.t(),
          max_body_bytes: non_neg_integer() | :infinity,
          body_limit_ref: :atomics.atomics_ref()
        }

  @spec new(Enumerable.t(), non_neg_integer() | :infinity) :: t()
  def new(stream, max_body_bytes) do
    %__MODULE__{
      stream: stream,
      max_body_bytes: max_body_bytes,
      body_limit_ref: :atomics.new(1, [])
    }
  end

  @spec body_limit_exceeded?(t()) :: boolean()
  def body_limit_exceeded?(%__MODULE__{body_limit_ref: body_limit_ref}) do
    :atomics.get(body_limit_ref, 1) == 1
  end

  @spec mark_body_limit_exceeded(t()) :: :ok
  def mark_body_limit_exceeded(%__MODULE__{body_limit_ref: body_limit_ref}) do
    :atomics.put(body_limit_ref, 1, 1)
    :ok
  end
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

    try do
      stream
      |> Enumerable.reduce({:cont, {0, acc}}, reducer(wrapped, fun, consumer_failure_ref))
      |> unwrap_result(fun, consumer_failure_ref)
    rescue
      error in StreamError ->
        reraise error, __STACKTRACE__

      _error ->
        reraise StreamError.exception(reason: :stream_exception), __STACKTRACE__
    catch
      {^consumer_failure_ref, kind, reason, stacktrace} ->
        :erlang.raise(kind, reason, stacktrace)

      _kind, _reason ->
        raise StreamError, reason: :stream_exception
    end
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
        case call_consumer(fun, binary, acc, consumer_failure_ref) do
          {:cont, acc} -> {:cont, {new_size, acc}}
          {:halt, acc} -> {:halt, {new_size, acc}}
          {:suspend, acc} -> {:suspend, {new_size, acc}}
        end
      else
        {:error, :body_too_large} ->
          WrappedStream.mark_body_limit_exceeded(wrapped)
          raise StreamError, reason: :body_too_large

        {:error, reason} ->
          raise StreamError, reason: reason
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
    continuation.(command)
    |> unwrap_result(fun, consumer_failure_ref)
  rescue
    error in StreamError ->
      reraise error, __STACKTRACE__

    _error ->
      reraise StreamError.exception(reason: :stream_exception), __STACKTRACE__
  catch
    {^consumer_failure_ref, kind, reason, stacktrace} ->
      :erlang.raise(kind, reason, stacktrace)

    _kind, _reason ->
      raise StreamError, reason: :stream_exception
  end
end
