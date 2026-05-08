defmodule ImagePlug.Parser.Native do
  @moduledoc """
  Parser for ImagePlug's native path-oriented URL syntax.
  """

  use Boundary,
    deps: [
      ImagePlug.Parser,
      ImagePlug.Plan,
      ImagePlug.Transform
    ],
    exports: []

  @behaviour ImagePlug.Parser

  alias ImagePlug.Parser.Native.CacheRequest
  alias ImagePlug.Parser.Native.CropRequest
  alias ImagePlug.Parser.Native.OutputRequest
  alias ImagePlug.Parser.Native.ParsedRequest
  alias ImagePlug.Parser.Native.PipelineRequest
  alias ImagePlug.Parser.Native.PlanBuilder
  alias ImagePlug.Parser.Native.RequestPolicy
  alias ImagePlug.Parser.Native.ResponseRequest
  alias ImagePlug.Plan.Orientation
  alias ImagePlug.Plan.Response.Filename

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

  def parse(%Plug.Conn{} = conn), do: parse(conn, [])

  @impl ImagePlug.Parser
  def parse(%Plug.Conn{} = conn, opts) do
    with {:ok, parsed_request} <- parse_request(conn, opts) do
      PlanBuilder.to_plan(parsed_request, opts)
    end
  end

  @doc false
  def parse_request(%Plug.Conn{path_info: [signature | path_info]}, _opts) do
    with :ok <- validate_signature(signature),
         {:ok, option_segments, raw_source_path} <- split_source(path_info),
         {:ok, request_options} <- parse_request_options(option_segments),
         {:ok, source_path, source_format} <- parse_plain_source(raw_source_path) do
      parsed_request(
        signature,
        source_path,
        source_format,
        request_options
      )
    end
  end

  def parse_request(%Plug.Conn{path_info: []}, _opts) do
    {:error, :missing_signature}
  end

  @impl ImagePlug.Parser
  def handle_error(%Plug.Conn{} = conn, {:error, reason}) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(400, "invalid image request: #{inspect(reason)}")
  end

  defp validate_signature(signature) when signature in ["_", "unsafe"], do: :ok
  defp validate_signature(signature), do: {:error, {:unsupported_signature, signature}}

  defp parsed_request(
         signature,
         source_path,
         source_format,
         request_options
       ) do
    output_format = source_format || request_options.output.format

    {:ok,
     %ParsedRequest{
       signature: signature,
       source_kind: :plain,
       source_path: source_path,
       pipelines: request_options.pipelines,
       output: %{request_options.output | format: output_format},
       policy: request_options.policy,
       cache: request_options.cache,
       response: request_options.response
     }}
  end

  defp split_source(path_info) do
    case Enum.split_while(path_info, &(&1 != "plain")) do
      {_options, []} ->
        {:error, :missing_source_kind}

      {_options, ["plain"]} ->
        {:error, {:missing_source_identifier, "plain"}}

      {options, ["plain" | source_path]} ->
        {:ok, options, source_path}
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
        case parse_format(extension) do
          {:ok, format} -> decode_source_path(source, format)
          {:error, _reason} = error -> error
        end

      _parts ->
        {:error, {:multiple_source_format_separators, encoded}}
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

  defp parse_request_options(option_segments) do
    Enum.reduce_while(option_segments, {:ok, initial_request_options()}, fn
      "-", {:ok, options} ->
        {:cont, {:ok, finalize_current_pipeline(options)}}

      segment, {:ok, options} ->
        case parse_option(segment) do
          {:ok, {:pipeline, assignments}} ->
            {:cont, {:ok, update_current_pipeline(options, assignments)}}

          {:ok, {:output, assignments}} ->
            {:cont, {:ok, update_output(options, assignments)}}

          {:ok, {:cache, assignments}} ->
            {:cont, {:ok, update_cache(options, assignments)}}

          {:ok, {:policy, assignments}} ->
            {:cont, {:ok, update_policy(options, assignments)}}

          {:ok, {:response, assignments}} ->
            {:cont, {:ok, update_response(options, assignments)}}

          {:error, _reason} = error ->
            {:halt, error}
        end
    end)
    |> case do
      {:ok, options} -> {:ok, finalize_request_options(options)}
      {:error, _reason} = error -> error
    end
  end

  defp initial_request_options do
    %{
      current_pipeline: %PipelineRequest{},
      pipelines: [],
      output: %OutputRequest{},
      policy: %RequestPolicy{},
      cache: %CacheRequest{},
      response: %ResponseRequest{}
    }
  end

  defp finalize_request_options(options) do
    options = finalize_current_pipeline(options)
    pipelines = Enum.reverse(options.pipelines)

    pipelines =
      if pipelines == [] do
        [%PipelineRequest{}]
      else
        pipelines
      end

    %{options | current_pipeline: %PipelineRequest{}, pipelines: pipelines}
  end

  defp finalize_current_pipeline(%{current_pipeline: pipeline, pipelines: pipelines} = options) do
    if pipeline_empty?(pipeline) do
      %{options | current_pipeline: %PipelineRequest{}}
    else
      %{options | current_pipeline: %PipelineRequest{}, pipelines: [pipeline | pipelines]}
    end
  end

  defp update_current_pipeline(%{current_pipeline: pipeline} = options, assignments) do
    pipeline =
      Enum.reduce(assignments, pipeline, fn
        {:orientation, orientation_assignments}, pipeline ->
          %{
            pipeline
            | orientation: struct!(pipeline.orientation, orientation_assignments),
              orientation_requested: true
          }

        assignment, pipeline ->
          struct!(pipeline, [assignment])
      end)

    %{options | current_pipeline: pipeline}
  end

  defp update_output(%{output: output} = options, assignments) do
    output =
      Enum.reduce(assignments, output, fn
        {:format_qualities, format_qualities}, output ->
          %{
            output
            | format_qualities: Map.merge(output.format_qualities, format_qualities)
          }

        assignment, output ->
          struct!(output, [assignment])
      end)

    %{options | output: output}
  end

  defp update_cache(%{cache: cache} = options, assignments) do
    %{options | cache: struct!(cache, assignments)}
  end

  defp update_policy(%{policy: policy} = options, assignments) do
    %{options | policy: struct!(policy, assignments)}
  end

  defp update_response(%{response: response} = options, assignments) do
    %{options | response: struct!(response, assignments)}
  end

  defp pipeline_empty?(%PipelineRequest{
         width: nil,
         height: nil,
         min_width: nil,
         min_height: nil,
         resizing_type: :fit,
         zoom_x: nil,
         zoom_y: nil,
         dpr: nil,
         enlarge: false,
         extend: false,
         extend_requested: false,
         extend_gravity: nil,
         extend_x_offset: nil,
         extend_y_offset: nil,
         extend_aspect_ratio: nil,
         gravity: {:anchor, :center, :center},
         gravity_x_offset: gravity_x_offset,
         gravity_y_offset: gravity_y_offset,
         crop: nil,
         orientation_requested: false,
         orientation: %Orientation{} = orientation
       })
       when gravity_x_offset in [{:pixels, 0.0}, 0.0] and
              gravity_y_offset in [{:pixels, 0.0}, 0.0] do
    orientation == %Orientation{}
  end

  defp pipeline_empty?(%PipelineRequest{}), do: false

  defp parse_option(segment) do
    [name | args] = String.split(segment, ":")

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
         {:ok, filename} <- Filename.new(decoded) do
      {:ok, [filename: filename.stem]}
    end
  end

  defp parse_filename(value, true) do
    with :ok <- reject_base64_padding(value),
         {:ok, decoded} <- Base.url_decode64(value, padding: false),
         {:ok, filename} <- Filename.new(decoded) do
      {:ok, [filename: filename.stem]}
    else
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
  defp parse_field(:format, value), do: parse_format(value)
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

  defp parse_special_option(name, _args, _segment), do: {:error, {:unknown_option, name}}

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
