defmodule ImagePlug.ParamParser.Native do
  @behaviour ImagePlug.ParamParser

  alias ImagePlug.ProcessingRequest

  @source_format_names ~w(webp avif jpeg jpg png best)

  @source_formats %{
    "webp" => :webp,
    "avif" => :avif,
    "jpeg" => :jpeg,
    "jpg" => :jpeg,
    "png" => :png,
    "best" => :best
  }

  @resizing_types %{
    "fit" => :fit,
    "fill" => :fill,
    "fill-down" => :fill_down,
    "force" => :force,
    "auto" => :auto
  }

  @resizing_type_names ~w(fit fill fill-down force auto)

  @gravity_anchors %{
    "no" => {:anchor, :center, :top},
    "so" => {:anchor, :center, :bottom},
    "ea" => {:anchor, :right, :center},
    "we" => {:anchor, :left, :center},
    "noea" => {:anchor, :right, :top},
    "nowe" => {:anchor, :left, :top},
    "soea" => {:anchor, :right, :bottom},
    "sowe" => {:anchor, :left, :bottom},
    "ce" => {:anchor, :center, :center}
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
    Enum.reduce_while(option_segments, {:ok, []}, fn segment, {:ok, options} ->
      case parse_option(segment) do
        {:ok, assignments} ->
          {:cont, {:ok, Keyword.merge(options, assignments)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp parse_option("-"), do: {:error, :unsupported_chained_pipeline}

  defp parse_option(segment) do
    case String.split(segment, ":") do
      [key | args] when key in ["resize", "rs"] ->
        parse_resize(segment, args)

      [key | args] when key in ["size", "s"] ->
        parse_size(segment, args)

      [key, value] when key in ["resizing_type", "rt"] ->
        parse_resizing_type(value)

      [key | _args] when key in ["resizing_type", "rt"] ->
        {:error, {:invalid_option_segment, segment}}

      [key, value] when key in ["width", "w"] ->
        parse_pixels_option(:width, value)

      [key | _args] when key in ["width", "w"] ->
        {:error, {:invalid_option_segment, segment}}

      [key, value] when key in ["height", "h"] ->
        parse_pixels_option(:height, value)

      [key | _args] when key in ["height", "h"] ->
        {:error, {:invalid_option_segment, segment}}

      [key | args] when key in ["gravity", "g"] ->
        parse_gravity_option(segment, args)

      [key, value] when key in ["format", "f", "ext"] ->
        parse_format_option(value)

      [key | _args] when key in ["format", "f", "ext"] ->
        {:error, {:invalid_option_segment, segment}}

      [key | _args] ->
        {:error, {:unknown_option, key}}
    end
  end

  defp parse_resize(segment, args) when length(args) <= 8 do
    {fields, extend_gravity_parts} = Enum.split(args, 5)
    [resizing_type, width, height, enlarge, extend] = pad_optional(fields, 5)

    with {:ok, assignments} <-
           parse_optional_assignments([
             {:resizing_type, resizing_type, &parse_resizing_type_value/1},
             {:width, width, &parse_pixels/1},
             {:height, height, &parse_pixels/1},
             {:enlarge, enlarge, &parse_boolean/1},
             {:extend, extend, &parse_boolean/1}
           ]),
         {:ok, extend_gravity_assignments} <-
           parse_optional_extend_gravity(segment, extend_gravity_parts) do
      {:ok, assignments ++ extend_gravity_assignments}
    end
  end

  defp parse_resize(segment, _args), do: {:error, {:invalid_option_segment, segment}}

  defp parse_size(segment, args) when length(args) <= 7 do
    {fields, extend_gravity_parts} = Enum.split(args, 4)
    [width, height, enlarge, extend] = pad_optional(fields, 4)

    with {:ok, assignments} <-
           parse_optional_assignments([
             {:width, width, &parse_pixels/1},
             {:height, height, &parse_pixels/1},
             {:enlarge, enlarge, &parse_boolean/1},
             {:extend, extend, &parse_boolean/1}
           ]),
         {:ok, extend_gravity_assignments} <-
           parse_optional_extend_gravity(segment, extend_gravity_parts) do
      {:ok, assignments ++ extend_gravity_assignments}
    end
  end

  defp parse_size(segment, _args), do: {:error, {:invalid_option_segment, segment}}

  defp parse_optional_assignments(fields) do
    fields
    |> Enum.reduce_while({:ok, []}, fn
      {_field, value, _parser}, {:ok, assignments} when value in [nil, ""] ->
        {:cont, {:ok, assignments}}

      {field, value, parser}, {:ok, assignments} ->
        case parser.(value) do
          {:ok, parsed_value} -> {:cont, {:ok, [{field, parsed_value} | assignments]}}
          {:error, _reason} = error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, assignments} -> {:ok, Enum.reverse(assignments)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_optional_extend_gravity(_segment, []), do: {:ok, []}
  defp parse_optional_extend_gravity(_segment, [""]), do: {:ok, []}
  defp parse_optional_extend_gravity(_segment, ["", ""]), do: {:ok, []}
  defp parse_optional_extend_gravity(_segment, ["", "", ""]), do: {:ok, []}

  defp parse_optional_extend_gravity(_segment, [gravity]) do
    with {:ok, anchor} <- parse_gravity_anchor(gravity) do
      {:ok, [extend_gravity: anchor]}
    end
  end

  defp parse_optional_extend_gravity(_segment, [gravity, "", ""]) do
    with {:ok, anchor} <- parse_gravity_anchor(gravity) do
      {:ok, [extend_gravity: anchor]}
    end
  end

  defp parse_optional_extend_gravity(_segment, [gravity, x_offset, y_offset]) do
    with {:ok, anchor} <- parse_gravity_anchor(gravity),
         {:ok, x_offset} <- parse_float(x_offset),
         {:ok, y_offset} <- parse_float(y_offset) do
      {:ok,
       [
         extend_gravity: anchor,
         extend_x_offset: x_offset,
         extend_y_offset: y_offset
       ]}
    end
  end

  defp parse_optional_extend_gravity(segment, _parts),
    do: {:error, {:invalid_option_segment, segment}}

  defp parse_resizing_type(value) do
    with {:ok, resizing_type} <- parse_resizing_type_value(value) do
      {:ok, resizing_type: resizing_type}
    end
  end

  defp parse_resizing_type_value(value) do
    case Map.fetch(@resizing_types, value) do
      {:ok, resizing_type} -> {:ok, resizing_type}
      :error -> {:error, {:invalid_resizing_type, value, @resizing_type_names}}
    end
  end

  defp parse_pixels_option(field, value) do
    with {:ok, pixels} <- parse_pixels(value) do
      {:ok, [{field, pixels}]}
    end
  end

  defp parse_pixels(value) do
    with {:ok, integer} <- parse_non_negative_integer(value) do
      {:ok, {:pixels, integer}}
    end
  end

  defp parse_boolean(value) do
    case value do
      value when value in ["1", "t", "true"] -> {:ok, true}
      value when value in ["0", "f", "false"] -> {:ok, false}
      value -> {:error, {:invalid_boolean, value}}
    end
  end

  defp parse_gravity_option(_segment, ["sm"]), do: {:ok, [gravity: :sm]}

  defp parse_gravity_option(_segment, ["fp", x, y]) do
    with {:ok, x} <- parse_focal_coordinate(x),
         {:ok, y} <- parse_focal_coordinate(y) do
      {:ok, [gravity: {:fp, x, y}, gravity_x_offset: 0.0, gravity_y_offset: 0.0]}
    end
  end

  defp parse_gravity_option(_segment, [anchor]) do
    with {:ok, anchor} <- parse_gravity_anchor(anchor) do
      {:ok, [gravity: anchor, gravity_x_offset: 0.0, gravity_y_offset: 0.0]}
    end
  end

  defp parse_gravity_option(_segment, [anchor, x_offset, y_offset]) do
    with {:ok, anchor} <- parse_gravity_anchor(anchor),
         {:ok, x_offset} <- parse_float(x_offset),
         {:ok, y_offset} <- parse_float(y_offset) do
      {:ok, [gravity: anchor, gravity_x_offset: x_offset, gravity_y_offset: y_offset]}
    end
  end

  defp parse_gravity_option(segment, _args), do: {:error, {:invalid_option_segment, segment}}

  defp parse_gravity_anchor(value) do
    case Map.fetch(@gravity_anchors, value) do
      {:ok, anchor} -> {:ok, anchor}
      :error -> {:error, {:invalid_gravity, value}}
    end
  end

  defp parse_focal_coordinate(value) do
    case parse_float(value) do
      {:ok, float} when float >= 0.0 and float <= 1.0 ->
        {:ok, float}

      {:ok, _float} ->
        {:error, {:invalid_gravity_coordinate, value}}

      {:error, _reason} ->
        {:error, {:invalid_gravity_coordinate, value}}
    end
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {float, ""} ->
        {:ok, float}

      _other ->
        case Integer.parse(value) do
          {integer, ""} -> {:ok, integer * 1.0}
          _other -> {:error, {:invalid_float, value}}
        end
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, {:invalid_non_negative_integer, value}}
    end
  end

  defp parse_format_option(value) do
    with {:ok, format} <- parse_format(value) do
      {:ok, [format: format]}
    end
  end

  defp pad_optional(values, count) do
    values ++ List.duplicate(nil, count - length(values))
  end
end
