defmodule ImagePlug.Parser.Imgproxy.Path do
  @moduledoc false

  alias ImagePlug.Parser.Imgproxy.Format

  @no_arg_option_segments ~w(- ar auto_rotate fl flip preset pr)

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
      {_options, ["plain"]} ->
        {:error, {:missing_source_identifier, "plain"}}

      {options, ["plain" | source_path]} ->
        {:ok, options, :plain, source_path}

      {_options, []} ->
        split_encoded_source(path_info)
    end
  end

  def parse_source(:plain, source_path), do: parse_plain_source(source_path)
  def parse_source(:encoded, source_path), do: parse_encoded_source(source_path)

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
        case Format.parse(extension) do
          {:ok, format} -> decode_source_path(source, format)
          {:error, _reason} = error -> error
        end

      _parts ->
        {:error, {:multiple_output_extension_separators, encoded}}
    end
  end

  defp split_encoded_source(path_info) do
    case split_encoded_source(path_info, []) do
      {:ok, _options, []} ->
        {:error, :missing_source_kind}

      {:ok, _options, ["enc" | _source_segments]} ->
        {:error, {:unsupported_source_kind, "enc"}}

      {:ok, options, source_segments} ->
        {:ok, options, :encoded, source_segments}

      {:error, _reason} = error ->
        error
    end
  end

  defp split_encoded_source([], options), do: {:ok, Enum.reverse(options), []}

  defp split_encoded_source([segment | segments], options) do
    case classify_pre_source_segment(segment) do
      :option ->
        split_encoded_source(segments, [segment | options])

      :source_start ->
        {:ok, Enum.reverse(options), [segment | segments]}
    end
  end

  defp classify_pre_source_segment(segment) when segment in @no_arg_option_segments,
    do: :option

  defp classify_pre_source_segment(segment) do
    cond do
      String.contains?(segment, ":") ->
        :option

      true ->
        :source_start
    end
  end

  defp parse_encoded_source(source_path) do
    encoded = Enum.join(source_path, "")

    case String.split(encoded, ".") do
      [""] ->
        {:error, {:missing_source_identifier, "encoded"}}

      [source] ->
        decode_encoded_source(source, nil)

      ["", _extension] ->
        {:error, {:missing_source_identifier, "encoded"}}

      [source, ""] ->
        decode_encoded_source(source, nil)

      [source, extension] ->
        case Format.parse(extension) do
          {:ok, format} -> decode_encoded_source(source, format)
          {:error, _reason} = error -> error
        end

      _parts ->
        {:error, {:multiple_output_extension_separators, encoded}}
    end
  end

  defp decode_encoded_source(source, source_format) do
    source
    |> String.trim_trailing("=")
    |> Base.url_decode64(padding: false)
    |> case do
      {:ok, decoded} -> validate_decoded_source(decoded, source_format)
      :error -> {:error, {:invalid_encoded_source, :base64}}
    end
  end

  defp validate_decoded_source(decoded, source_format) do
    case String.valid?(decoded) do
      true -> {:ok, decoded, source_format}
      false -> {:error, {:invalid_encoded_source, :utf8}}
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
    with :ok <- validate_percent_encoded_segments(source) do
      {:ok, source, source_format}
    end
  end

  defp validate_percent_encoded_segments(source) do
    source
    |> String.split("/", trim: false)
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, decoded_segments} ->
      case decode_percent_encoded(segment) do
        {:ok, decoded_segment} -> {:cont, {:ok, [decoded_segment | decoded_segments]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _decoded_segments} -> :ok
      {:error, _reason} = error -> error
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
