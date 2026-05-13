defmodule ImagePlug.Origin do
  @moduledoc """
  Origin URL construction and minimal Req-backed HTTP streaming.

  `fetch/2` returns a stream that starts the Req request when the image decoder
  consumes it. This keeps the Req async messages in the same process that
  enumerates the body, which is required because libvips consumes source
  enumerables outside the request process.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Plan],
    exports: [
      Decoded,
      Identity,
      Response
    ]

  defmodule Response do
    @moduledoc false

    @enforce_keys [:stream]
    defstruct @enforce_keys

    @type t() :: %__MODULE__{
            stream: Enumerable.t()
          }
  end

  @default_max_body_bytes 10_000_000
  @default_receive_timeout 5_000
  @default_pool_timeout 5_000
  @default_connect_timeout 5_000
  @default_max_redirects 3

  def build_url(root_url, path_segments) when is_binary(root_url) and is_list(path_segments) do
    root_uri = URI.parse(root_url)

    with :ok <- validate_root_url(root_uri, root_url),
         :ok <- validate_path_segments(path_segments) do
      {:ok, build_origin_url(root_uri, path_segments)}
    end
  end

  def fetch(url, req_options \\ []) when is_binary(url) and is_list(req_options) do
    {:ok,
     %Response{
       stream: response_stream(url, req_options)
     }}
  end

  defp response_stream(url, req_options) do
    max_body_bytes = Keyword.get(req_options, :max_body_bytes, @default_max_body_bytes)
    receive_timeout = Keyword.get(req_options, :receive_timeout, @default_receive_timeout)

    Stream.resource(
      fn -> open_response(url, req_options, max_body_bytes, receive_timeout) end,
      fn
        %{response: %Req.Response{}} = state ->
          stream_response(state)

        {:done, %{response: %Req.Response{} = response}} ->
          {:halt, response}

        {:error, _reason} = error ->
          {:halt, error}
      end,
      fn
        %{response: %Req.Response{} = response} -> cancel_response(response)
        {:done, %{response: %Req.Response{} = response}} -> cancel_response(response)
        _other -> :ok
      end
    )
  end

  defp open_response(url, req_options, max_body_bytes, receive_timeout) do
    request_options = request_options(url, req_options)

    case Req.get(request_options,
           receive_timeout: receive_timeout,
           pool_timeout: Keyword.get(req_options, :pool_timeout, @default_pool_timeout),
           connect_options: connect_options(req_options)
         ) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        %{
          response: response,
          max_body_bytes: max_body_bytes,
          receive_timeout: receive_timeout,
          size: 0
        }

      {:ok, %Req.Response{status: status} = response} ->
        cancel_response(response)
        {:error, {:bad_status, status}}

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp stream_response(
         %{response: %Req.Response{body: %Req.Response.Async{ref: ref}} = response} = state
       ) do
    with {:ok, message} <- next_message(ref, state.receive_timeout),
         {:ok, chunks} <- parse_message(response, message),
         {:ok, data_chunks, size} <- data_chunks(chunks, state) do
      if Enum.any?(chunks, &(&1 == :done)) do
        {data_chunks, {:done, %{state | size: size}}}
      else
        {data_chunks, %{state | size: size}}
      end
    else
      {:error, _reason} = error -> {:halt, error}
      :unknown -> stream_response(state)
    end
  end

  defp next_message(ref, receive_timeout) do
    receive do
      {^ref, _message} = message -> {:ok, message}
    after
      receive_timeout -> {:error, {:timeout, receive_timeout}}
    end
  end

  defp parse_message(response, message) do
    case Req.parse_message(response, message) do
      {:ok, chunks} -> {:ok, chunks}
      {:error, exception} -> {:error, {:transport, exception}}
      :unknown -> :unknown
    end
  end

  defp data_chunks(chunks, state) do
    data_chunks = for {:data, data} <- chunks, do: data
    size = Enum.reduce(data_chunks, state.size, &(&2 + byte_size(&1)))

    if is_integer(state.max_body_bytes) and size > state.max_body_bytes do
      {:error, {:body_too_large, state.max_body_bytes}}
    else
      {:ok, data_chunks, size}
    end
  end

  defp request_options(url, req_options) do
    req_options
    |> Keyword.delete(:max_body_bytes)
    |> Keyword.delete(:receive_timeout)
    |> Keyword.delete(:pool_timeout)
    |> Keyword.delete(:connect_options)
    |> Keyword.merge(
      url: url,
      into: :self,
      retry: false,
      redirect: true,
      max_redirects: Keyword.get(req_options, :max_redirects, @default_max_redirects)
    )
  end

  defp valid_root_url?(%URI{scheme: scheme, host: host})
       when scheme in ["http", "https"] and is_binary(host) and host != "",
       do: true

  defp valid_root_url?(_root_uri), do: false

  defp validate_root_url(root_uri, root_url) do
    if valid_root_url?(root_uri), do: :ok, else: {:error, {:invalid_root_url, root_url}}
  end

  defp validate_path_segments(path_segments) do
    if Enum.any?(path_segments, &(&1 in [".", ".."])),
      do: {:error, {:invalid_path_segment, path_segments}},
      else: :ok
  end

  defp build_origin_url(root_uri, path_segments) do
    path =
      (split_path(root_uri.path) ++ Enum.map(path_segments, &encode_path_segment/1))
      |> Enum.join("/")

    root_uri
    |> Map.put(:path, "/" <> path)
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  defp encode_path_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp split_path(nil), do: []
  defp split_path(""), do: []
  defp split_path(path), do: path |> String.trim("/") |> String.split("/", trim: true)

  defp connect_options(req_options) do
    req_options
    |> Keyword.get(:connect_options, [])
    |> Keyword.put_new(:timeout, @default_connect_timeout)
  end

  defp cancel_response(%Req.Response{} = response) do
    Req.cancel_async_response(response)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
