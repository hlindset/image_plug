defmodule ImagePlug.ParamParser.Native do
  @behaviour ImagePlug.ParamParser

  alias ImagePlug.ProcessingRequest

  @source_format_names ~w(webp avif jpeg jpg png best)
  @processing_format_names ~w(auto webp avif jpeg png)

  @fits %{
    "cover" => :cover,
    "contain" => :contain,
    "fill" => :fill,
    "inside" => :inside
  }

  @source_formats %{
    "webp" => :webp,
    "avif" => :avif,
    "jpeg" => :jpeg,
    "jpg" => :jpeg,
    "png" => :png,
    "best" => :best
  }

  @processing_formats %{
    "auto" => :auto,
    "webp" => :webp,
    "avif" => :avif,
    "jpeg" => :jpeg,
    "png" => :png
  }

  @focus_anchors %{
    "center" => {:anchor, :center, :center},
    "top" => {:anchor, :center, :top},
    "bottom" => {:anchor, :center, :bottom},
    "left" => {:anchor, :left, :center},
    "right" => {:anchor, :right, :center}
  }

  @impl ImagePlug.ParamParser
  def parse(%Plug.Conn{path_info: [signature | path_info]}) do
    with :ok <- validate_signature(signature),
         {:ok, option_segments, source_path, source_format} <- split_source(path_info),
         {:ok, options} <- parse_options(option_segments) do
      options =
        case source_format do
          nil -> options
          format -> Keyword.put(options, :format, format)
        end

      {:ok,
       struct!(
         ProcessingRequest,
         Keyword.merge(
           [
             signature: signature,
             source_kind: :plain,
             source_path: source_path,
             output_extension_from_source: source_format
           ],
           options
         )
       )}
    end
  end

  def parse(%Plug.Conn{path_info: []}) do
    {:error, :missing_signature}
  end

  @impl ImagePlug.ParamParser
  def handle_error(%Plug.Conn{} = conn, {:error, reason}) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(400, "invalid image request: #{inspect(reason)}")
  end

  defp validate_signature(signature) when signature in ["_", "unsafe"], do: :ok
  defp validate_signature(signature), do: {:error, {:unsupported_signature, signature}}

  defp split_source(path_info) do
    case Enum.split_while(path_info, &(&1 != "plain")) do
      {_options, []} ->
        {:error, :missing_source_kind}

      {_options, ["plain"]} ->
        {:error, {:missing_source_identifier, "plain"}}

      {options, ["plain" | source_path]} ->
        with {:ok, decoded_source_path, source_format} <- parse_plain_source(source_path) do
          {:ok, options, decoded_source_path, source_format}
        end
    end
  end

  defp parse_plain_source(source_path) do
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
        with {:ok, format} <- parse_format(extension) do
          decode_source_path(source, format)
        end

      _parts ->
        {:error, {:multiple_source_format_separators, encoded}}
    end
  end

  defp decode_source_path(source, source_format) do
    decoded =
      source
      |> String.split("/", trim: false)
      |> Enum.map(&URI.decode/1)

    {:ok, decoded, source_format}
  end

  defp parse_format(value) do
    case Map.fetch(@source_formats, value) do
      {:ok, parsed_value} -> {:ok, parsed_value}
      :error -> {:error, {:invalid_format, value, @source_format_names}}
    end
  end

  defp parse_options(option_segments) do
    Enum.reduce_while(option_segments, {:ok, MapSet.new(), []}, fn segment,
                                                                   {:ok, seen, options} ->
      case option_field(segment) do
        {:ok, field} ->
          if MapSet.member?(seen, field) do
            {:halt, {:error, {:duplicate_option, field}}}
          else
            case parse_option(segment) do
              {:ok, ^field, value} ->
                {:cont, {:ok, MapSet.put(seen, field), [{field, value} | options]}}

              {:error, _reason} = error ->
                {:halt, error}
            end
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, _seen, options} -> {:ok, Enum.reverse(options)}
      {:error, _reason} = error -> error
    end
  end

  defp option_field(segment) do
    case segment |> String.split(":", parts: 2) |> hd() do
      "w" -> {:ok, :width}
      "h" -> {:ok, :height}
      "fit" -> {:ok, :fit}
      "focus" -> {:ok, :focus}
      "format" -> {:ok, :format}
      key -> {:error, {:unknown_option, key}}
    end
  end

  defp parse_option(segment) do
    case String.split(segment, ":") do
      ["w", value] ->
        with {:ok, pixels} <- parse_positive_pixels(value) do
          {:ok, :width, pixels}
        end

      ["w" | _rest] ->
        {:error, {:invalid_option_segment, segment}}

      ["h", value] ->
        with {:ok, pixels} <- parse_positive_pixels(value) do
          {:ok, :height, pixels}
        end

      ["h" | _rest] ->
        {:error, {:invalid_option_segment, segment}}

      ["fit", value] ->
        parse_mapped_option(:fit, value, @fits, {:invalid_fit, value})

      ["fit" | _rest] ->
        {:error, {:invalid_option_segment, segment}}

      ["focus", value] ->
        parse_focus(value)

      ["focus", x, y] ->
        parse_focus_coordinate(x, y)

      ["focus" | _rest] ->
        {:error, {:invalid_option_segment, segment}}

      ["format", value] ->
        parse_mapped_option(
          :format,
          value,
          @processing_formats,
          {:invalid_format, value, @processing_format_names}
        )

      ["format" | _rest] ->
        {:error, {:invalid_option_segment, segment}}

      [key | _rest] ->
        {:error, {:unknown_option, key}}
    end
  end

  defp parse_mapped_option(field, value, values, error) do
    case Map.fetch(values, value) do
      {:ok, parsed_value} -> {:ok, field, parsed_value}
      :error -> {:error, error}
    end
  end

  defp parse_focus(value) do
    case Map.fetch(@focus_anchors, value) do
      {:ok, focus} -> {:ok, :focus, focus}
      :error -> {:error, {:invalid_focus, value}}
    end
  end

  defp parse_focus_coordinate(x, y) do
    with {:ok, parsed_x} <- parse_length(x),
         {:ok, parsed_y} <- parse_length(y) do
      {:ok, :focus, {:coordinate, parsed_x, parsed_y}}
    end
  end

  defp parse_positive_pixels(value) do
    with {:ok, integer} <- parse_positive_integer(value) do
      {:ok, {:pixels, integer}}
    end
  end

  defp parse_length(value) do
    case String.split_at(value, -1) do
      {number, "p"} ->
        parse_percent(value, number)

      _ ->
        with {:ok, integer} <- parse_non_negative_integer(value) do
          {:ok, {:pixels, integer}}
        end
    end
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:invalid_positive_integer, value}}
    end
  end

  defp parse_percent(value, number) do
    case Integer.parse(number) do
      {integer, ""} when integer >= 0 and integer <= 100 -> {:ok, {:percent, integer}}
      _other -> {:error, {:invalid_percent, value}}
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, {:invalid_non_negative_integer, value}}
    end
  end
end
