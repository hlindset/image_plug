defmodule ImagePlug.Parser.Imgproxy.Path do
  @moduledoc false

  @source_format_names ~w(webp avif jpeg jpg png best)

  @source_formats %{
    "webp" => :webp,
    "avif" => :avif,
    "jpeg" => :jpeg,
    "jpg" => :jpeg,
    "png" => :png,
    "best" => :best
  }

  def extract(%Plug.Conn{} = conn) do
    case parser_request_path(conn) do
      "/" ->
        {:error, :missing_signature}

      "/" <> raw_path ->
        raw_path
        |> :binary.split("/", [:global])
        |> raw_path_parts()

      _path ->
        {:error, :missing_signature}
    end
  end

  def split_source(path_info) do
    case Enum.split_while(path_info, &(&1 != "plain")) do
      {_options, []} ->
        {:error, :missing_source_kind}

      {_options, ["plain"]} ->
        {:error, {:missing_source_identifier, "plain"}}

      {options, ["plain" | source_path]} ->
        {:ok, options, source_path}
    end
  end

  def parse_plain_source(source_path) do
    encoded = Enum.join(source_path, "/")

    case String.split(encoded, "@") do
      [""] ->
        {:error, {:missing_source_identifier, "plain"}}

      [source] ->
        decode_source_path(source, nil)

      ["", _extension] ->
        {:error, {:missing_source_identifier, "plain"}}

      [source, ""] ->
        decode_source_path(source, nil)

      [source, extension] ->
        case parse_format(extension) do
          {:ok, format} -> decode_source_path(source, format)
          {:error, _reason} = error -> error
        end

      _parts ->
        {:error, {:multiple_source_format_separators, encoded}}
    end
  end

  defp parser_request_path(%Plug.Conn{request_path: request_path, script_name: []}),
    do: request_path

  defp parser_request_path(%Plug.Conn{request_path: request_path, script_name: script_name}) do
    prefix = "/" <> Enum.join(script_name, "/")

    cond do
      request_path == prefix ->
        "/"

      String.starts_with?(request_path, prefix <> "/") ->
        String.replace_prefix(request_path, prefix, "")

      true ->
        request_path
    end
  end

  defp raw_path_parts(["" | _raw_path_info]), do: {:error, :missing_signature}
  defp raw_path_parts([_signature]), do: {:error, :missing_signed_path}

  defp raw_path_parts([signature | raw_path_info]) do
    signed_path =
      raw_path_info
      |> Enum.join("/")
      |> then(&("/" <> &1))
      |> fix_path()

    {:ok, signature, signed_path, path_info_from_signed_path(signed_path)}
  end

  defp path_info_from_signed_path(""), do: []
  defp path_info_from_signed_path("/" <> path), do: :binary.split(path, "/", [:global])

  defp fix_path(path) do
    case :binary.split(path, "/plain/") do
      [options, plain_url] ->
        fix_options_path(options) <> "/plain/" <> fix_plain_url_path(plain_url)

      [options] ->
        fix_options_path(options)
    end
  end

  defp fix_options_path(options), do: String.replace(options, ~r/%3a/i, ":")

  defp fix_plain_url_path(plain_url) do
    case Regex.run(~r/^(\S+):\/([^\/])/, plain_url) do
      [match, "local", first] ->
        String.replace_prefix(plain_url, match, "local:///" <> first)

      [match, scheme, first] ->
        String.replace_prefix(plain_url, match, scheme <> "://" <> first)

      nil ->
        plain_url
    end
  end

  defp decode_source_path(source, source_format) do
    with {:ok, decoded} <- decode_source_segments(source) do
      {:ok, decoded, source_format}
    end
  end

  defp decode_source_segments(source) do
    source
    |> String.split("/", trim: false)
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, decoded_segments} ->
      case decode_percent_encoded(segment) do
        {:ok, decoded_segment} -> {:cont, {:ok, [decoded_segment | decoded_segments]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded_segments} -> {:ok, Enum.reverse(decoded_segments)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_format(value) do
    case Map.fetch(@source_formats, value) do
      {:ok, parsed_value} -> {:ok, parsed_value}
      :error -> {:error, {:invalid_format, value, @source_format_names}}
    end
  end

  defp decode_percent_encoded(value) do
    if malformed_percent_encoding?(value) do
      {:error, {:invalid_percent_encoding, value}}
    else
      {:ok, URI.decode(value)}
    end
  rescue
    ArgumentError -> {:error, {:invalid_percent_encoding, value}}
  end

  defp malformed_percent_encoding?(value) do
    String.match?(value, ~r/%($|[^0-9A-Fa-f]|[0-9A-Fa-f]$|[0-9A-Fa-f][^0-9A-Fa-f])/)
  end
end
