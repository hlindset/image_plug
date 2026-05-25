defmodule ImagePipe.Source.ReqStream do
  @moduledoc false

  alias ImagePipe.Source.StreamError

  @default_receive_timeout 5_000
  @default_pool_timeout 5_000
  @default_connect_timeout 5_000

  @spec stream(keyword(), keyword()) :: Enumerable.t()
  def stream(req_options, runtime_opts) when is_list(req_options) and is_list(runtime_opts) do
    Stream.resource(
      fn -> open_response(req_options, runtime_opts) end,
      fn
        %{response: %Req.Response{}} = state ->
          stream_response(state)

        {:done, %{response: %Req.Response{} = response}} ->
          {:halt, response}

        {:error, reason} ->
          raise StreamError, reason: reason
      end,
      fn
        %{response: %Req.Response{} = response} -> cancel_response(response)
        {:done, %{response: %Req.Response{} = response}} -> cancel_response(response)
        _other -> :ok
      end
    )
  end

  defp open_response(req_options, runtime_opts) do
    request_options = request_options(req_options)

    case Req.get(request_options,
           receive_timeout:
             timeout(req_options, runtime_opts, :receive_timeout, @default_receive_timeout),
           pool_timeout: timeout(req_options, runtime_opts, :pool_timeout, @default_pool_timeout),
           connect_options: connect_options(req_options, runtime_opts)
         ) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        %{
          response: response,
          receive_timeout:
            timeout(req_options, runtime_opts, :receive_timeout, @default_receive_timeout)
        }

      {:ok, %Req.Response{} = response} ->
        cancel_response(response)
        {:error, :bad_status}

      {:error, _exception} ->
        {:error, :bad_status}
    end
  end

  defp stream_response(
         %{response: %Req.Response{body: %Req.Response.Async{ref: ref}} = response} = state
       ) do
    with {:ok, message} <- next_message(ref, state.receive_timeout),
         {:ok, chunks} <- parse_message(response, message) do
      data_chunks = for {:data, data} <- chunks, do: data

      if Enum.any?(chunks, &(&1 == :done)) do
        {data_chunks, {:done, state}}
      else
        {data_chunks, state}
      end
    else
      {:error, reason} -> raise StreamError, reason: reason
      :unknown -> stream_response(state)
    end
  end

  defp next_message(ref, receive_timeout) do
    receive do
      {^ref, _message} = message -> {:ok, message}
    after
      receive_timeout -> {:error, :bad_status}
    end
  end

  defp parse_message(response, message) do
    case Req.parse_message(response, message) do
      {:ok, chunks} -> {:ok, chunks}
      {:error, _exception} -> {:error, :bad_status}
      :unknown -> :unknown
    end
  end

  defp request_options(req_options) do
    Keyword.merge(req_options,
      into: :self,
      retry: false
    )
  end

  defp connect_options(req_options, runtime_opts) do
    req_options
    |> Keyword.get(:connect_options, [])
    |> Keyword.put_new(
      :timeout,
      timeout(req_options, runtime_opts, :connect_timeout, @default_connect_timeout)
    )
  end

  defp timeout(req_options, runtime_opts, key, default) do
    Keyword.get(runtime_opts, key, Keyword.get(req_options, key, default))
  end

  defp cancel_response(%Req.Response{} = response) do
    Req.cancel_async_response(response)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
