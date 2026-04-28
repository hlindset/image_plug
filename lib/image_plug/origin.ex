defmodule ImagePlug.Origin do
  defmodule Response do
    @enforce_keys [:body, :content_type, :headers, :url]
    defstruct [:body, :content_type, :headers, :url]
  end

  @default_max_body_bytes 10_000_000
  @default_receive_timeout 5_000
  @default_max_redirects 3

  def build_url(root_url, path_segments) when is_binary(root_url) and is_list(path_segments) do
    root_uri = URI.parse(root_url)

    if valid_root_url?(root_uri) do
      if Enum.any?(path_segments, &(&1 in [".", ".."])) do
        {:error, {:invalid_path_segment, path_segments}}
      else
        root_path_segments = split_path(root_uri.path)

        encoded_path_segments =
          Enum.map(path_segments, fn segment ->
            URI.encode(segment, &URI.char_unreserved?/1)
          end)

        path = "/" <> Enum.join(root_path_segments ++ encoded_path_segments, "/")

        url =
          root_uri
          |> Map.put(:path, path)
          |> Map.put(:query, nil)
          |> Map.put(:fragment, nil)
          |> URI.to_string()

        {:ok, url}
      end
    else
      {:error, {:invalid_root_url, root_url}}
    end
  end

  def fetch(url, req_options \\ []) when is_binary(url) and is_list(req_options) do
    max_body_bytes = Keyword.get(req_options, :max_body_bytes, @default_max_body_bytes)

    request_options =
      req_options
      |> Keyword.delete(:max_body_bytes)
      |> Keyword.merge(
        url: url,
        into: :self,
        retry: false,
        redirect: true,
        max_redirects: @default_max_redirects,
        receive_timeout: @default_receive_timeout
      )

    case Req.get(request_options) do
      {:ok, response} ->
        handle_response(response, url, max_body_bytes, @default_receive_timeout)

      {:error, exception} ->
        {:error, {:transport, exception}}
    end
  end

  defp valid_root_url?(%URI{scheme: scheme, host: host})
       when scheme in ["http", "https"] and is_binary(host) and host != "",
       do: true

  defp valid_root_url?(_root_uri), do: false

  defp split_path(nil), do: []
  defp split_path(""), do: []
  defp split_path(path), do: path |> String.trim("/") |> String.split("/", trim: true)

  defp handle_response(%Req.Response{} = response, url, max_body_bytes, receive_timeout) do
    with :ok <- validate_status(response),
         {:ok, content_type} <- validate_content_type(response),
         {:ok, body} <- collect_body(response, max_body_bytes, receive_timeout) do
      {:ok,
       %Response{
         body: body,
         content_type: content_type,
         headers: response_headers(response),
         url: url
       }}
    else
      {:error, reason} = error ->
        cancel_response(response)

        case reason do
          {:bad_status, _status} -> error
          {:bad_content_type, _content_type} -> error
          {:body_too_large, _limit} -> error
          {:timeout, _receive_timeout} -> error
          {:transport, _exception} -> error
        end
    end
  end

  defp validate_status(%Req.Response{status: status}) when status in 200..299, do: :ok
  defp validate_status(%Req.Response{status: status}), do: {:error, {:bad_status, status}}

  defp validate_content_type(%Req.Response{} = response) do
    content_type = response |> Req.Response.get_header("content-type") |> List.first()
    media_type = content_type |> normalize_content_type()

    if is_binary(media_type) and String.starts_with?(media_type, "image/") do
      {:ok, content_type}
    else
      {:error, {:bad_content_type, content_type}}
    end
  end

  defp normalize_content_type(content_type) when is_binary(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_content_type(_content_type), do: nil

  defp response_headers(%Req.Response{headers: headers}) do
    Enum.flat_map(headers, fn {key, values} -> Enum.map(values, &{key, &1}) end)
  end

  defp collect_body(response, max_body_bytes, receive_timeout) do
    do_collect_body(response, max_body_bytes, receive_timeout, [], 0)
  end

  defp do_collect_body(response, max_body_bytes, receive_timeout, chunks, size) do
    receive do
      message ->
        case Req.parse_message(response, message) do
          {:ok, parsed_chunks} ->
            collect_chunks(response, parsed_chunks, max_body_bytes, receive_timeout, chunks, size)

          {:error, exception} ->
            {:error, {:transport, exception}}

          :unknown ->
            do_collect_body(response, max_body_bytes, receive_timeout, chunks, size)
        end
    after
      receive_timeout ->
        {:error, {:timeout, receive_timeout}}
    end
  end

  defp collect_chunks(response, parsed_chunks, max_body_bytes, receive_timeout, chunks, size) do
    Enum.reduce_while(parsed_chunks, {:cont, chunks, size}, fn
      {:data, data}, {:cont, chunks, size} ->
        size = size + byte_size(data)

        if size > max_body_bytes do
          {:halt, {:error, {:body_too_large, max_body_bytes}}}
        else
          {:cont, {:cont, [data | chunks], size}}
        end

      :done, {:cont, chunks, _size} ->
        {:halt, {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}}

      {:trailers, _trailers}, acc ->
        {:cont, acc}
    end)
    |> case do
      {:cont, chunks, size} ->
        do_collect_body(response, max_body_bytes, receive_timeout, chunks, size)

      result ->
        result
    end
  end

  defp cancel_response(%Req.Response{} = response) do
    Req.cancel_async_response(response)
  rescue
    _ -> :ok
  end
end
