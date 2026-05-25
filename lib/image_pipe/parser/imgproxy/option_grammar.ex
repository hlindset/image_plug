defmodule ImagePipe.Parser.Imgproxy.OptionGrammar do
  @moduledoc false

  alias ImagePipe.Parser.Imgproxy.CropRequest
  alias ImagePipe.Parser.Imgproxy.Format
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Response

  @resizing_types %{
    "fit" => :fit,
    "fill" => :fill,
    "fill-down" => :fill_down,
    "force" => :force,
    "auto" => :auto
  }

  @resizing_type_names ~w(fit fill fill-down force auto)

  @option_specs %{
    "resize" => {:resize, [:resizing_type, :width, :height, :enlarge, :extend]},
    "rs" => {:resize, [:resizing_type, :width, :height, :enlarge, :extend]},
    "size" => {:size, [:width, :height, :enlarge, :extend]},
    "s" => {:size, [:width, :height, :enlarge, :extend]},
    "resizing_type" => {:resizing_type, [:resizing_type]},
    "rt" => {:resizing_type, [:resizing_type]},
    "width" => {:width, [:width]},
    "w" => {:width, [:width]},
    "height" => {:height, [:height]},
    "h" => {:height, [:height]},
    "min-width" => {:min_width, [:min_width]},
    "min_width" => {:min_width, [:min_width]},
    "mw" => {:min_width, [:min_width]},
    "min-height" => {:min_height, [:min_height]},
    "min_height" => {:min_height, [:min_height]},
    "mh" => {:min_height, [:min_height]},
    "enlarge" => {:enlarge, [:enlarge]},
    "el" => {:enlarge, [:enlarge]},
    "format" => {:format, [:format]},
    "f" => {:format, [:format]},
    "ext" => {:format, [:format]},
    "quality" => {:quality, [:quality]},
    "q" => {:quality, [:quality]},
    "format_quality" => {:format_quality, [:format, :quality]},
    "fq" => {:format_quality, [:format, :quality]},
    "cachebuster" => {:cachebuster, [:cachebuster]},
    "cb" => {:cachebuster, [:cachebuster]},
    "expires" => {:expires, [:expires]},
    "exp" => {:expires, [:expires]},
    "filename" => {:filename, [:filename]},
    "fn" => {:filename, [:filename]},
    "return_attachment" => {:return_attachment, [:return_attachment]},
    "att" => {:return_attachment, [:return_attachment]}
  }

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

  @spec parse(String.t()) ::
          {:ok, {:preset, [String.t()]}}
          | {:ok, {:pipeline | :output | :cache | :policy | :response, keyword()}}
          | {:error, term()}
  def parse(segment) do
    case String.split(segment, ":") do
      [name] when name in ["preset", "pr"] ->
        {:error, {:invalid_option_segment, segment}}

      [name | args] when name in ["preset", "pr"] ->
        parse_preset_args(args, segment)

      [name | args] ->
        parse_non_preset_option(name, args, segment)
    end
  end

  defp parse_preset_args(args, segment) do
    case Enum.any?(args, &(&1 == "")) do
      true -> {:error, {:invalid_option_segment, segment}}
      false -> {:ok, {:preset, args}}
    end
  end

  defp parse_non_preset_option(name, args, segment) do
    case Map.fetch(@option_specs, name) do
      {:ok, {kind, fields}} ->
        with {:ok, assignments} <- parse_known_option(kind, fields, args, segment) do
          {:ok, scoped_assignments(kind, assignments)}
        end

      :error ->
        with {:ok, assignments} <- parse_special_option(name, args, segment) do
          {:ok, {:pipeline, assignments}}
        end
    end
  end

  defp scoped_assignments(kind, assignments) when kind in [:format, :quality, :format_quality],
    do: {:output, assignments}

  defp scoped_assignments(:cachebuster, assignments), do: {:cache, assignments}

  defp scoped_assignments(:expires, assignments), do: {:policy, assignments}

  defp scoped_assignments(kind, assignments) when kind in [:filename, :return_attachment],
    do: {:response, assignments}

  defp scoped_assignments(_kind, assignments), do: {:pipeline, assignments}

  defp parse_known_option(kind, fields, args, segment)
       when kind in [:resizing_type, :width, :height, :min_width, :min_height, :enlarge, :format] do
    parse_exact_fields(fields, args, segment)
  end

  defp parse_known_option(:quality, [:quality], [value], segment) when value != "" do
    parse_exact_fields([:quality], [value], segment)
  end

  defp parse_known_option(:cachebuster, [:cachebuster], [value], _segment) when value != "" do
    {:ok, [cachebuster: value]}
  end

  defp parse_known_option(:expires, [:expires], [value], _segment) when value != "" do
    case parse_non_negative_integer(value) do
      {:ok, expires} -> {:ok, [expires: expires]}
      {:error, _reason} -> {:error, {:invalid_expires, value}}
    end
  end

  defp parse_known_option(:filename, [:filename], [value], _segment) when value != "" do
    parse_filename(value, false)
  end

  defp parse_known_option(:filename, [:filename], [value, encoded], segment)
       when value != "" and encoded != "" do
    with {:ok, encoded?} <- parse_boolean(encoded),
         {:ok, assignments} <- parse_filename(value, encoded?) do
      {:ok, assignments}
    else
      {:error, {:invalid_boolean, _value}} -> {:error, {:invalid_option_segment, segment}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_known_option(:return_attachment, [:return_attachment], [value], segment)
       when value != "" do
    case parse_boolean(value) do
      {:ok, true} -> {:ok, [disposition: :attachment]}
      {:ok, false} -> {:ok, [disposition: :inline]}
      {:error, {:invalid_boolean, _value}} -> {:error, {:invalid_option_segment, segment}}
    end
  end

  defp parse_known_option(:format_quality, [:format, :quality], [format, value], segment)
       when format != "" and value != "" do
    with {:ok, assignments} <- parse_exact_fields([:format, :quality], [format, value], segment),
         {:ok, format} <- Keyword.fetch(assignments, :format),
         {:ok, quality} <- Keyword.fetch(assignments, :quality) do
      {:ok, [format_qualities: %{format => quality}]}
    end
  end

  defp parse_known_option(:resize, fields, args, segment) when length(args) <= 8 do
    with {base_args, extend_gravity_parts} <- Enum.split(args, 5),
         {:ok, assignments} <- parse_fields(fields, base_args, skip_empty: true),
         {:ok, extend_gravity_assignments} <-
           parse_optional_extend_gravity(segment, extend_gravity_parts) do
      assignments =
        assignments
        |> Keyword.merge(explicit_extend_assignment(fields, base_args))
        |> Keyword.merge(extend_gravity_assignments)

      reject_empty_assignments(segment, assignments)
    end
  end

  defp parse_known_option(:size, fields, args, segment) when length(args) <= 7 do
    with {base_args, extend_gravity_parts} <- Enum.split(args, 4),
         {:ok, assignments} <- parse_fields(fields, base_args, skip_empty: true),
         {:ok, extend_gravity_assignments} <-
           parse_optional_extend_gravity(segment, extend_gravity_parts) do
      assignments =
        assignments
        |> Keyword.merge(explicit_extend_assignment(fields, base_args))
        |> Keyword.merge(extend_gravity_assignments)

      reject_empty_assignments(segment, assignments)
    end
  end

  defp parse_known_option(_kind, _fields, _args, segment),
    do: {:error, {:invalid_option_segment, segment}}

  defp parse_filename(value, false) do
    with {:ok, decoded} <- decode_percent_encoded(value),
         true <- Response.valid_filename?(decoded) do
      {:ok, [filename: decoded]}
    else
      false -> {:error, {:invalid_response_filename, value}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_filename(value, true) do
    with :ok <- reject_base64_padding(value),
         {:ok, decoded} <- Base.url_decode64(value, padding: false),
         true <- Response.valid_filename?(decoded) do
      {:ok, [filename: decoded]}
    else
      false -> {:error, {:invalid_response_filename, value}}
      :error -> {:error, {:invalid_response_filename, value}}
      {:error, _reason} = error -> error
    end
  end

  defp reject_base64_padding(value) do
    if String.contains?(value, "=") do
      {:error, {:invalid_response_filename, value}}
    else
      :ok
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

  defp parse_exact_fields(fields, args, _segment) when length(args) == length(fields) do
    parse_fields(fields, args)
  end

  defp parse_exact_fields(_fields, _args, segment),
    do: {:error, {:invalid_option_segment, segment}}

  defp reject_empty_assignments(segment, []), do: {:error, {:invalid_option_segment, segment}}
  defp reject_empty_assignments(_segment, assignments), do: {:ok, assignments}

  defp explicit_extend_assignment(fields, args) do
    index = Enum.find_index(fields, &(&1 == :extend))
    value = if is_nil(index), do: nil, else: Enum.at(args, index)

    if value in [nil, ""] do
      []
    else
      [extend_requested: true]
    end
  end

  defp parse_fields(fields, args, opts \\ []) do
    skip_empty? = Keyword.get(opts, :skip_empty, false)

    result =
      fields
      |> Enum.zip(args)
      |> Enum.reduce_while({:ok, []}, fn
        {_field, value}, {:ok, assignments} when skip_empty? and value in [nil, ""] ->
          {:cont, {:ok, assignments}}

        {field, value}, {:ok, assignments} ->
          case parse_field(field, value) do
            {:ok, parsed_value} -> {:cont, {:ok, [{field, parsed_value} | assignments]}}
            {:error, _reason} = error -> {:halt, error}
          end
      end)

    case result do
      {:ok, assignments} -> {:ok, Enum.reverse(assignments)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_field(:resizing_type, value), do: parse_resizing_type_value(value)
  defp parse_field(:width, value), do: parse_pixels(value)
  defp parse_field(:height, value), do: parse_pixels(value)
  defp parse_field(:min_width, value), do: parse_pixels(value)
  defp parse_field(:min_height, value), do: parse_pixels(value)
  defp parse_field(:enlarge, value), do: parse_boolean(value)
  defp parse_field(:extend, value), do: parse_boolean(value)
  defp parse_field(:format, value), do: Format.parse(value)
  defp parse_field(:quality, value), do: parse_quality(value)

  defp parse_optional_extend_gravity(_segment, []), do: {:ok, []}
  defp parse_optional_extend_gravity(_segment, [""]), do: {:ok, []}
  defp parse_optional_extend_gravity(_segment, ["", ""]), do: {:ok, []}
  defp parse_optional_extend_gravity(_segment, ["", "", ""]), do: {:ok, []}

  defp parse_optional_extend_gravity(_segment, [gravity]) do
    case parse_gravity_anchor(gravity) do
      {:ok, anchor} -> {:ok, [extend_gravity: anchor]}
      {:error, _reason} = error -> error
    end
  end

  defp parse_optional_extend_gravity(_segment, [gravity, "", ""]) do
    case parse_gravity_anchor(gravity) do
      {:ok, anchor} -> {:ok, [extend_gravity: anchor]}
      {:error, _reason} = error -> error
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

  defp parse_resizing_type_value(value) do
    case Map.fetch(@resizing_types, value) do
      {:ok, resizing_type} -> {:ok, resizing_type}
      :error -> {:error, {:invalid_resizing_type, value, @resizing_type_names}}
    end
  end

  defp parse_pixels(value) do
    case parse_non_negative_integer(value) do
      {:ok, integer} -> {:ok, {:pixels, integer}}
      {:error, _reason} = error -> error
    end
  end

  defp parse_boolean(value) when value in ["1", "t", "true"], do: {:ok, true}
  defp parse_boolean(value) when value in ["0", "f", "false"], do: {:ok, false}
  defp parse_boolean(value), do: {:error, {:invalid_boolean, value}}

  defp parse_special_option(name, args, segment) when name in ["zoom", "z"] do
    parse_zoom(args, segment)
  end

  defp parse_special_option("dpr", args, segment) do
    parse_dpr(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["extend", "ex"] do
    parse_extend(args, segment)
  end

  defp parse_special_option(name, args, segment)
       when name in ["extend_aspect_ratio", "extend_ar", "exar"] do
    parse_extend_aspect_ratio(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["crop", "c"] do
    parse_crop(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["auto_rotate", "ar"] do
    parse_auto_rotate(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["rotate", "rot"] do
    parse_rotate(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["flip", "fl"] do
    parse_flip(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["gravity", "g"] do
    parse_gravity(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["padding", "pd"] do
    parse_padding(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["background", "bg"] do
    parse_background(args, segment)
  end

  defp parse_special_option(name, args, segment) when name in ["background_alpha", "bga"] do
    parse_background_alpha(args, segment)
  end

  defp parse_special_option(name, _args, _segment), do: {:error, {:unknown_option, name}}

  defp parse_padding(args, segment) when length(args) <= 4 do
    with {:ok, parsed_args} <- parse_padding_args(args, segment) do
      {:ok, [padding: parsed_args]}
    end
  end

  defp parse_padding(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_padding_args(args, segment) do
    parse_padding_args(args, segment, [])
  end

  defp parse_padding_args([], _segment, values), do: {:ok, Enum.reverse(values)}

  defp parse_padding_args([arg | args], segment, values) do
    case parse_padding_arg(arg) do
      {:ok, value} -> parse_padding_args(args, segment, [value | values])
      {:error, _reason} -> {:error, {:invalid_option_segment, segment}}
    end
  end

  defp parse_padding_arg(""), do: {:ok, :unset}
  defp parse_padding_arg(value), do: parse_non_negative_integer(value)

  defp parse_background([""], _segment), do: {:ok, [background_color: nil]}

  defp parse_background([hex], _segment) when hex != "" do
    with {:ok, color} <- Color.rgb_hex(hex) do
      {:ok, [background_color: color]}
    else
      {:error, _reason} -> {:error, {:invalid_background, hex}}
    end
  end

  defp parse_background([red, green, blue], _segment)
       when red != "" and green != "" and blue != "" do
    with {:ok, red} <- parse_non_negative_integer(red),
         {:ok, green} <- parse_non_negative_integer(green),
         {:ok, blue} <- parse_non_negative_integer(blue),
         {:ok, color} <- Color.rgb(red, green, blue) do
      {:ok, [background_color: color]}
    else
      {:error, _reason} -> {:error, {:invalid_background, [red, green, blue]}}
    end
  end

  defp parse_background(args, _segment), do: {:error, {:invalid_background, args}}

  defp parse_background_alpha([alpha], _segment) when alpha != "" do
    with {:ok, alpha} <- parse_alpha_ratio(alpha) do
      {:ok, [background_alpha: alpha]}
    else
      {:error, _reason} -> {:error, {:invalid_background_alpha, alpha}}
    end
  end

  defp parse_background_alpha(args, _segment), do: {:error, {:invalid_background_alpha, args}}

  defp parse_alpha_ratio(value) do
    case String.split(value, ".", parts: 2) do
      [integer] -> parse_alpha_integer(integer)
      [integer, fraction] -> parse_alpha_decimal(integer, fraction)
    end
  end

  defp parse_alpha_integer("0"), do: {:ok, {:ratio, 0, 1}}
  defp parse_alpha_integer("1"), do: {:ok, {:ratio, 1, 1}}
  defp parse_alpha_integer(_integer), do: {:error, :alpha}

  defp parse_alpha_decimal(integer, fraction) when integer in ["0", "1"] and fraction != "" do
    with true <- decimal_digits?(fraction),
         {fraction_value, ""} <- Integer.parse(fraction, 10) do
      denominator = Integer.pow(10, byte_size(fraction))
      numerator = String.to_integer(integer) * denominator + fraction_value

      case numerator >= 0 and numerator <= denominator do
        true -> {:ok, {:ratio, numerator, denominator}}
        false -> {:error, :alpha}
      end
    else
      _reason -> {:error, :alpha}
    end
  end

  defp parse_alpha_decimal(_integer, _fraction), do: {:error, :alpha}

  defp decimal_digits?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(&(&1 in ?0..?9))
  end

  defp parse_zoom([value], _segment) when value != "" do
    with {:ok, zoom} <- parse_positive_float(value) do
      {:ok, [zoom_x: zoom, zoom_y: zoom]}
    end
  end

  defp parse_zoom([x, y], _segment) when x != "" and y != "" do
    with {:ok, x} <- parse_positive_float(x),
         {:ok, y} <- parse_positive_float(y) do
      {:ok, [zoom_x: x, zoom_y: y]}
    end
  end

  defp parse_zoom(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_dpr([value], _segment) when value != "" do
    with {:ok, dpr} <- parse_positive_float(value) do
      {:ok, [dpr: dpr]}
    end
  end

  defp parse_dpr(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_extend([value], _segment) when value != "" do
    with {:ok, extend?} <- parse_boolean(value) do
      {:ok, [extend: extend?, extend_requested: true]}
    end
  end

  defp parse_extend([value | gravity_parts], segment) when value != "" do
    with {:ok, extend?} <- parse_boolean(value),
         {:ok, extend_gravity_assignments} <-
           parse_optional_extend_gravity(segment, gravity_parts) do
      {:ok, Keyword.merge([extend: extend?, extend_requested: true], extend_gravity_assignments)}
    end
  end

  defp parse_extend(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_extend_aspect_ratio([width, height], _segment) when width != "" and height != "" do
    with {:ok, width} <- parse_positive_number(width),
         {:ok, height} <- parse_positive_number(height) do
      {:ok, [extend_aspect_ratio: {width, height}]}
    end
  end

  defp parse_extend_aspect_ratio(_args, segment),
    do: {:error, {:invalid_option_segment, segment}}

  defp parse_crop([width, height], _segment) when width != "" and height != "" do
    with {:ok, width} <- parse_crop_dimension(width),
         {:ok, height} <- parse_crop_dimension(height) do
      {:ok, [crop: %CropRequest{width: width, height: height}]}
    end
  end

  defp parse_crop([width, height, gravity], _segment)
       when width != "" and height != "" and gravity != "" do
    with {:ok, width} <- parse_crop_dimension(width),
         {:ok, height} <- parse_crop_dimension(height),
         {:ok, gravity} <- parse_crop_gravity([gravity]) do
      {:ok, [crop: %CropRequest{width: width, height: height, gravity: gravity}]}
    end
  end

  defp parse_crop([width, height, "fp", x, y], _segment)
       when width != "" and height != "" and x != "" and y != "" do
    with {:ok, width} <- parse_crop_dimension(width),
         {:ok, height} <- parse_crop_dimension(height),
         {:ok, gravity} <- parse_crop_gravity(["fp", x, y]) do
      {:ok, [crop: %CropRequest{width: width, height: height, gravity: gravity}]}
    end
  end

  defp parse_crop([width, height, gravity, x_offset, y_offset], _segment)
       when width != "" and height != "" and gravity != "" and x_offset != "" and y_offset != "" do
    with {:ok, width} <- parse_crop_dimension(width),
         {:ok, height} <- parse_crop_dimension(height),
         {:ok, gravity} <- parse_gravity_anchor(gravity),
         {:ok, x_offset} <- parse_gravity_offset(x_offset),
         {:ok, y_offset} <- parse_gravity_offset(y_offset) do
      {:ok,
       [
         crop: %CropRequest{
           width: width,
           height: height,
           gravity: gravity,
           x_offset: x_offset,
           y_offset: y_offset
         }
       ]}
    end
  end

  defp parse_crop(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_crop_gravity(["sm"]), do: {:ok, :sm}

  defp parse_crop_gravity(["fp", x, y]) do
    with {:ok, x} <- parse_focal_coordinate(x),
         {:ok, y} <- parse_focal_coordinate(y) do
      {:ok, {:fp, x, y}}
    end
  end

  defp parse_crop_gravity([anchor]), do: parse_gravity_anchor(anchor)
  defp parse_crop_gravity(_args), do: {:error, {:invalid_option_segment, "crop"}}

  defp parse_auto_rotate([], _segment), do: {:ok, [orientation: [auto_orient: true]]}

  defp parse_auto_rotate([value], _segment) when value != "" do
    with {:ok, auto_orient?} <- parse_boolean(value) do
      {:ok, [orientation: [auto_orient: auto_orient?]]}
    end
  end

  defp parse_auto_rotate(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_rotate([value], _segment) when value != "" do
    case Integer.parse(value) do
      {integer, ""} when rem(integer, 90) == 0 ->
        {:ok, [orientation: [rotate: normalize_rotation(integer)]]}

      _other ->
        {:error, {:invalid_rotate, value}}
    end
  end

  defp parse_rotate(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_flip([], _segment), do: {:ok, [orientation: [flip: :both]]}

  defp parse_flip([horizontal], _segment) when horizontal != "" do
    with {:ok, horizontal?} <- parse_boolean(horizontal) do
      {:ok, [orientation: [flip: flip_value(horizontal?, false)]]}
    end
  end

  defp parse_flip([horizontal, vertical], _segment) when horizontal != "" and vertical != "" do
    with {:ok, horizontal?} <- parse_boolean(horizontal),
         {:ok, vertical?} <- parse_boolean(vertical) do
      {:ok, [orientation: [flip: flip_value(horizontal?, vertical?)]]}
    end
  end

  defp parse_flip(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_gravity(["sm"], _segment), do: {:ok, [gravity: :sm]}

  defp parse_gravity(["fp", x, y], _segment) do
    with {:ok, x} <- parse_focal_coordinate(x),
         {:ok, y} <- parse_focal_coordinate(y) do
      {:ok,
       [gravity: {:fp, x, y}, gravity_x_offset: {:pixels, 0.0}, gravity_y_offset: {:pixels, 0.0}]}
    end
  end

  defp parse_gravity([anchor], _segment) do
    with {:ok, anchor} <- parse_gravity_anchor(anchor) do
      {:ok, [gravity: anchor, gravity_x_offset: {:pixels, 0.0}, gravity_y_offset: {:pixels, 0.0}]}
    end
  end

  defp parse_gravity([anchor, x_offset, y_offset], _segment) do
    with {:ok, anchor} <- parse_gravity_anchor(anchor),
         {:ok, x_offset} <- parse_gravity_offset(x_offset),
         {:ok, y_offset} <- parse_gravity_offset(y_offset) do
      {:ok, [gravity: anchor, gravity_x_offset: x_offset, gravity_y_offset: y_offset]}
    end
  end

  defp parse_gravity(_args, segment), do: {:error, {:invalid_option_segment, segment}}

  defp parse_gravity_anchor(value) do
    case Map.fetch(@gravity_anchors, value) do
      {:ok, anchor} -> {:ok, anchor}
      :error -> {:error, {:invalid_gravity, value}}
    end
  end

  defp parse_gravity_offset(value) do
    case parse_float(value) do
      {:ok, float} when float == 0.0 -> {:ok, {:pixels, 0.0}}
      {:ok, float} when abs(float) >= 1.0 -> {:ok, {:pixels, float}}
      {:ok, float} -> {:ok, {:scale, float}}
      {:error, _reason} = error -> error
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

  defp normalize_rotation(value) do
    value
    |> rem(360)
    |> Kernel.+(360)
    |> rem(360)
  end

  defp flip_value(true, true), do: :both
  defp flip_value(true, false), do: :horizontal
  defp flip_value(false, true), do: :vertical
  defp flip_value(false, false), do: nil

  defp parse_crop_dimension(value) do
    case parse_number(value) do
      {:ok, number} when number == 0 ->
        {:ok, :auto}

      {:ok, number} when number > 0 and number < 1 ->
        {:ok, {:scale, number}}

      {:ok, number} when number >= 1 ->
        {:ok, {:pixels, number}}

      {:ok, _number} ->
        {:error, {:invalid_crop_dimension, value}}

      {:error, _reason} ->
        {:error, {:invalid_crop_dimension, value}}
    end
  end

  defp parse_positive_float(value) do
    case parse_float(value) do
      {:ok, float} when float > 0.0 -> {:ok, float}
      {:ok, _float} -> {:error, {:invalid_positive_float, value}}
      {:error, _reason} -> {:error, {:invalid_positive_float, value}}
    end
  end

  defp parse_positive_number(value) do
    case parse_number(value) do
      {:ok, number} when number > 0 -> {:ok, number}
      {:ok, _number} -> {:error, {:invalid_positive_number, value}}
      {:error, _reason} -> {:error, {:invalid_positive_number, value}}
    end
  end

  defp parse_number(value) do
    case Integer.parse(value) do
      {integer, ""} ->
        {:ok, integer}

      _other ->
        parse_float(value)
    end
  end

  defp parse_float(value) do
    case Float.parse(value) do
      {float, ""} -> {:ok, float}
      _other -> {:error, {:invalid_float, value}}
    end
  end

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, {:invalid_non_negative_integer, value}}
    end
  end

  defp parse_quality("0"), do: {:ok, :default}

  defp parse_quality(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 1..100 -> {:ok, {:quality, integer}}
      _other -> {:error, {:invalid_option, :quality, value}}
    end
  end
end
