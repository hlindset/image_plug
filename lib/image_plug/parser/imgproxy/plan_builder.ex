defmodule ImagePlug.Parser.Imgproxy.PlanBuilder do
  @moduledoc false

  alias ImagePlug.Parser.Imgproxy.CacheRequest
  alias ImagePlug.Parser.Imgproxy.CropRequest
  alias ImagePlug.Parser.Imgproxy.OutputRequest
  alias ImagePlug.Parser.Imgproxy.ParsedRequest
  alias ImagePlug.Parser.Imgproxy.PipelineRequest
  alias ImagePlug.Parser.Imgproxy.RequestPolicy
  alias ImagePlug.Parser.Imgproxy.ResponseRequest
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Cache
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Orientation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Policy
  alias ImagePlug.Plan.Response
  alias ImagePlug.Plan.Response.Filename
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Rotate

  @default_gravity {:anchor, :center, :center}
  @supported_output_formats [:webp, :avif, :jpeg, :png]

  @spec to_plan(ParsedRequest.t(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def to_plan(%ParsedRequest{} = request, opts \\ []) do
    with {:ok, source} <- source_plan(request.source_kind, request.source_path),
         {:ok, output} <- output_plan(request.output),
         {:ok, policy} <- policy_plan(request.policy, opts),
         {:ok, cache} <- cache_plan(request.cache),
         {:ok, response} <- response_plan(request.response, source),
         {:ok, pipelines} <- build_pipelines(request.pipelines) do
      {:ok,
       %Plan{
         source: source,
         pipelines: pipelines,
         output: output,
         policy: policy,
         cache: cache,
         response: response
       }}
    end
  end

  defp source_plan(:plain, path), do: {:ok, %Plain{path: path}}
  defp source_plan(kind, _path), do: {:error, {:unsupported_source_kind, kind}}

  defp build_pipelines([]), do: {:error, :empty_pipeline_plan}

  defp build_pipelines(pipeline_requests) do
    result =
      Enum.reduce_while(pipeline_requests, [], fn pipeline_request, pipelines ->
        case pipeline(pipeline_request) do
          {:ok, pipeline} -> {:cont, [pipeline | pipelines]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:error, _reason} = error -> error
      pipelines -> {:ok, Enum.reverse(pipelines)}
    end
  end

  defp pipeline(%PipelineRequest{} = pipeline_request) do
    with :ok <- validate_supported_semantics(pipeline_request),
         {:ok, operations} <- plan_geometry(pipeline_request) do
      {:ok, %Pipeline{operations: operations}}
    end
  end

  defp reduce_results(results) do
    result =
      Enum.reduce_while(results, {:ok, []}, fn
        {:ok, value}, {:ok, values} -> {:cont, {:ok, [value | values]}}
        {:error, reason}, {:ok, _values} -> {:halt, {:error, reason}}
      end)

    case result do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp output_plan(%OutputRequest{format: nil} = request) do
    {:ok,
     %Output{
       mode: :automatic,
       quality: request.quality,
       format_qualities: request.format_qualities
     }}
  end

  defp output_plan(%OutputRequest{format: :best}),
    do: {:error, {:unsupported_output_format, :best}}

  defp output_plan(%OutputRequest{format: format} = request)
       when format in @supported_output_formats do
    {:ok,
     %Output{
       mode: {:explicit, format},
       quality: request.quality,
       format_qualities: request.format_qualities
     }}
  end

  defp policy_plan(%RequestPolicy{expires: 0}, _opts), do: {:ok, %Policy{expires: 0}}

  defp policy_plan(%RequestPolicy{expires: expires}, opts)
       when is_integer(expires) and expires > 0 do
    with {:ok, now} <- now_unix_seconds(opts),
         :ok <- reject_expired_request(expires, now) do
      {:ok, %Policy{expires: expires}}
    end
  end

  defp reject_expired_request(expires, now) do
    if Policy.expired?(%Policy{expires: expires}, now) do
      {:error, {:expired_request, expires}}
    else
      :ok
    end
  end

  defp now_unix_seconds(opts) do
    case Keyword.fetch(opts, :now) do
      {:ok, now} when is_function(now, 0) -> normalize_now(now.())
      {:ok, now} -> normalize_now(now)
      :error -> {:ok, DateTime.to_unix(DateTime.utc_now())}
    end
  end

  defp normalize_now(%DateTime{} = now), do: {:ok, DateTime.to_unix(now)}
  defp normalize_now(now) when is_integer(now), do: {:ok, now}
  defp normalize_now(now), do: {:error, {:invalid_now, now}}

  defp cache_plan(%CacheRequest{cachebuster: cachebuster}),
    do: {:ok, %Cache{cachebuster: cachebuster}}

  defp response_plan(%ResponseRequest{filename: nil, disposition: disposition}, %Plain{
         path: source_path
       }) do
    with {:ok, filename} <- source_filename(source_path) do
      {:ok, %Response{filename: filename, disposition: disposition}}
    end
  end

  defp response_plan(%ResponseRequest{filename: filename, disposition: disposition}, %Plain{})
       when is_binary(filename) do
    with {:ok, filename} <- Filename.new(filename) do
      {:ok, %Response{filename: filename, disposition: disposition}}
    end
  end

  defp source_filename(source_path) do
    source_path
    |> List.last()
    |> source_filename_stem()
    |> Filename.new()
    |> case do
      {:ok, filename} -> {:ok, filename}
      {:error, _reason} -> Filename.new("image")
    end
  end

  defp source_filename_stem(basename) when basename in [nil, ""], do: "image"

  defp source_filename_stem(basename) when is_binary(basename) do
    case Path.rootname(basename) do
      "" -> "image"
      stem -> stem
    end
  end

  defp validate_supported_semantics(%PipelineRequest{gravity: :sm}),
    do: {:error, {:unsupported_gravity, :sm}}

  defp validate_supported_semantics(%PipelineRequest{gravity: gravity} = request) do
    if valid_gravity?(gravity) do
      with :ok <- validate_extend_semantics(request),
           :ok <- validate_crop_semantics(request),
           :ok <- validate_orientation_semantics(request),
           do: validate_pending_pipeline_semantics(request)
    else
      {:error, {:invalid_gravity, gravity}}
    end
  end

  defp validate_extend_semantics(%PipelineRequest{} = request) do
    with :ok <- validate_extend_gravity(request.extend_gravity),
         :ok <- validate_extend_offset(request.extend_x_offset),
         :ok <- validate_extend_offset(request.extend_y_offset),
         :ok <- validate_gravity_offset(:x_offset, request.gravity_x_offset) do
      with :ok <- validate_gravity_offset(:y_offset, request.gravity_y_offset) do
        validate_extend_aspect_ratio(request.extend_aspect_ratio)
      end
    end
  end

  defp validate_extend_gravity(nil), do: :ok

  defp validate_extend_gravity({:anchor, _x, _y} = gravity) do
    if valid_gravity?(gravity), do: :ok, else: {:error, {:invalid_gravity, gravity}}
  end

  defp validate_extend_gravity(gravity), do: {:error, {:invalid_gravity, gravity}}

  defp validate_extend_offset(nil), do: :ok
  defp validate_extend_offset(offset) when is_number(offset), do: :ok
  defp validate_extend_offset(offset), do: {:error, {:invalid_extend_offset, offset}}

  defp validate_gravity_offset(_field, value) when is_number(value), do: :ok
  defp validate_gravity_offset(_field, {:pixels, value}) when is_number(value), do: :ok
  defp validate_gravity_offset(_field, {:scale, value}) when is_number(value), do: :ok

  defp validate_gravity_offset(field, value),
    do: {:error, {:invalid_gravity_offset, field, value}}

  defp validate_extend_aspect_ratio(nil), do: :ok

  defp validate_extend_aspect_ratio({width, height})
       when is_number(width) and is_number(height) and width > 0 and height > 0,
       do: :ok

  defp validate_extend_aspect_ratio(extend_aspect_ratio),
    do: {:error, {:invalid_extend_aspect_ratio, extend_aspect_ratio}}

  defp validate_crop_semantics(%PipelineRequest{crop: nil}), do: :ok

  defp validate_crop_semantics(%PipelineRequest{
         crop: %CropRequest{
           width: width,
           height: height,
           gravity: gravity,
           x_offset: x_offset,
           y_offset: y_offset
         }
       }) do
    with :ok <- validate_crop_dimension(:width, width),
         :ok <- validate_crop_dimension(:height, height),
         :ok <- validate_crop_gravity(gravity),
         :ok <- validate_crop_offset(:x_offset, x_offset) do
      validate_crop_offset(:y_offset, y_offset)
    end
  end

  defp validate_crop_dimension(_field, :auto), do: :ok

  defp validate_crop_dimension(_field, {:pixels, value}) when is_number(value) and value > 0,
    do: :ok

  defp validate_crop_dimension(_field, {:scale, value}) when is_number(value) and value > 0,
    do: :ok

  defp validate_crop_dimension(field, value),
    do: {:error, {:invalid_crop_dimension, field, value}}

  defp validate_crop_gravity(nil), do: :ok
  defp validate_crop_gravity(:sm), do: {:error, {:unsupported_gravity, :sm}}

  defp validate_crop_gravity(gravity) do
    if valid_gravity?(gravity), do: :ok, else: {:error, {:invalid_gravity, gravity}}
  end

  defp validate_crop_offset(_field, value) when is_number(value), do: :ok
  defp validate_crop_offset(_field, {:pixels, value}) when is_number(value), do: :ok
  defp validate_crop_offset(_field, {:scale, value}) when is_number(value), do: :ok
  defp validate_crop_offset(field, value), do: {:error, {:invalid_crop_offset, field, value}}

  defp validate_orientation_semantics(%PipelineRequest{orientation: %Orientation{}}), do: :ok

  defp validate_pending_pipeline_semantics(%PipelineRequest{} = request) do
    with :ok <- validate_factor(:zoom_x, request.zoom_x),
         :ok <- validate_factor(:zoom_y, request.zoom_y),
         :ok <- validate_factor(:dpr, request.dpr) do
      validate_pending_unimplemented_semantics(request)
    end
  end

  defp validate_factor(_field, nil), do: :ok
  defp validate_factor(_field, value) when is_number(value) and value > 0, do: :ok
  defp validate_factor(field, value), do: {:error, {:invalid_dimension_factor, field, value}}

  defp validate_pending_unimplemented_semantics(%PipelineRequest{}), do: :ok

  defp plan_geometry(%PipelineRequest{resizing_type: :fill, width: nil, height: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%PipelineRequest{resizing_type: :fill, width: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%PipelineRequest{resizing_type: :fill, height: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%PipelineRequest{resizing_type: resizing_type, width: nil})
       when resizing_type in [:fill_down, :auto],
       do: missing_dimensions(resizing_type)

  defp plan_geometry(%PipelineRequest{resizing_type: resizing_type, height: nil})
       when resizing_type in [:fill_down, :auto],
       do: missing_dimensions(resizing_type)

  defp plan_geometry(%PipelineRequest{} = request) do
    with {:ok, orientation_operations} <- orientation_operations(request),
         {:ok, crop_operations} <- crop_operations(request),
         {:ok, resize_operations} <- resize_operations(request),
         {:ok, canvas_operations} <- canvas_operations(request) do
      {:ok,
       orientation_operations ++
         crop_operations ++
         resize_operations ++ canvas_operations}
    end
  end

  defp crop_operations(%PipelineRequest{crop: nil}), do: {:ok, []}

  defp crop_operations(%PipelineRequest{crop: %CropRequest{} = crop} = request) do
    with {:ok, width} <- imgproxy_tagged_crop_dimension(crop.width),
         {:ok, height} <- imgproxy_tagged_crop_dimension(crop.height),
         {:ok, guide} <- tagged_gravity(crop.gravity || request.gravity),
         {:ok, operation} <-
           Operation.crop_guided(
             width,
             height,
             guide,
             x_offset: crop.x_offset,
             y_offset: crop.y_offset
           ) do
      {:ok, [operation]}
    end
  end

  defp orientation_operations(%PipelineRequest{orientation: %Orientation{} = orientation}) do
    operations =
      [
        auto_orient_operation(orientation),
        rotate_operation(orientation),
        flip_operation(orientation)
      ]
      |> Enum.reject(&is_nil/1)

    reduce_results(operations)
  end

  defp auto_orient_operation(%Orientation{auto_orient: true}),
    do: {:ok, %AutoOrient{}}

  defp auto_orient_operation(%Orientation{}), do: nil

  defp rotate_operation(%Orientation{rotate: 0}), do: nil

  defp rotate_operation(%Orientation{rotate: angle}) when angle in [90, 180, 270],
    do: {:ok, %Rotate{angle: angle}}

  defp flip_operation(%Orientation{flip: nil}), do: nil

  defp flip_operation(%Orientation{flip: axis}) when axis in [:horizontal, :vertical, :both],
    do: {:ok, %Flip{axis: axis}}

  defp result_crop_x_offset(%PipelineRequest{} = request) do
    offset = request.gravity_x_offset

    case request.gravity do
      {:anchor, :right, _y} -> negate_offset(offset)
      _gravity -> offset
    end
  end

  defp result_crop_y_offset(%PipelineRequest{} = request) do
    offset = request.gravity_y_offset

    case request.gravity do
      {:anchor, _x, :bottom} -> negate_offset(offset)
      _gravity -> offset
    end
  end

  defp negate_offset({unit, value}) when unit in [:pixels, :scale] and is_number(value),
    do: {unit, -value}

  defp negate_offset(value) when is_number(value), do: -value

  defp resize_operations(%PipelineRequest{width: nil, height: nil} = request) do
    if resize_rule_requested?(request) do
      resize_from_rule(request)
    else
      {:ok, []}
    end
  end

  defp resize_operations(%PipelineRequest{width: {:pixels, 0}, height: {:pixels, 0}} = request) do
    if resize_rule_requested?(request) do
      resize_from_rule(request)
    else
      {:ok, []}
    end
  end

  defp resize_operations(%PipelineRequest{resizing_type: :auto} = request) do
    with {:ok, operation} <- resize_operation(request) do
      {:ok, [operation]}
    end
  end

  defp resize_operations(%PipelineRequest{resizing_type: resizing_type} = request)
       when resizing_type in [:fit, :fill, :fill_down, :force] do
    resize_from_rule(request)
  end

  defp resize_from_rule(%PipelineRequest{} = request) do
    with {:ok, width} <- imgproxy_resize_dimension(request.width),
         {:ok, height} <- imgproxy_resize_dimension(request.height) do
      case {width, height, resize_rule_requested?(request)} do
        {:auto, :auto, false} ->
          {:ok, []}

        {_planned_width, _planned_height, _rule_requested?} ->
          build_operation_list(resize_operation(request))
      end
    end
  end

  defp resize_rule_requested?(%PipelineRequest{} = request) do
    not is_nil(request.min_width) or
      not is_nil(request.min_height) or
      not is_nil(request.zoom_x) or
      not is_nil(request.zoom_y) or
      not is_nil(request.dpr)
  end

  defp canvas_operations(%PipelineRequest{} = request) do
    operations =
      [
        extend_operation(request),
        extend_aspect_ratio_operation(request)
      ]
      |> Enum.reject(&is_nil/1)

    reduce_results(operations)
  end

  defp extend_operation(%PipelineRequest{} = request) do
    if extend_operation_requested?(request) do
      with {:ok, width} <- imgproxy_canvas_dimension(request.width),
           {:ok, height} <- imgproxy_canvas_dimension(request.height),
           {:ok, placement} <- canvas_placement(request.extend_gravity || @default_gravity) do
        Operation.canvas(
          width,
          height,
          placement,
          background: :white,
          overflow: :reject,
          x_offset: request.extend_x_offset || 0.0,
          y_offset: request.extend_y_offset || 0.0
        )
      end
    end
  end

  defp extend_operation_requested?(%PipelineRequest{extend: false, extend_requested: true}),
    do: false

  defp extend_operation_requested?(%PipelineRequest{} = request) do
    request.extend == true or
      not is_nil(request.extend_gravity) or
      not is_nil(request.extend_x_offset) or
      not is_nil(request.extend_y_offset)
  end

  defp extend_aspect_ratio_operation(%PipelineRequest{extend_aspect_ratio: nil}), do: nil

  defp extend_aspect_ratio_operation(%PipelineRequest{extend_aspect_ratio: ratio}) do
    with {:ok, width} <- tagged_ratio_from_decimal(elem(ratio, 0)),
         {:ok, height} <- tagged_ratio_from_decimal(elem(ratio, 1)),
         {:ok, placement} <- canvas_placement(@default_gravity) do
      Operation.canvas(width, height, placement, background: :white, overflow: :reject)
    end
  end

  defp resize_operation(%PipelineRequest{} = request) do
    with {:ok, width} <- imgproxy_resize_dimension(request.width),
         {:ok, height} <- imgproxy_resize_dimension(request.height),
         {:ok, min_width} <- optional_resize_dimension(request.min_width),
         {:ok, min_height} <- optional_resize_dimension(request.min_height),
         {:ok, guide} <- resize_guide(request.gravity) do
      resize_opts = [
        dpr: request.dpr || 1.0,
        enlargement: enlargement(request),
        guide: guide,
        min_width: min_width,
        min_height: min_height,
        zoom_x: request.zoom_x || 1.0,
        zoom_y: request.zoom_y || 1.0
      ]

      Operation.resize(
        resize_mode(request.resizing_type),
        width,
        height,
        resize_opts(request, resize_opts)
      )
    end
  end

  defp resize_opts(%PipelineRequest{resizing_type: resizing_type} = request, opts)
       when resizing_type in [:fill, :fill_down, :auto] do
    Keyword.merge(opts,
      x_offset: result_crop_x_offset(request),
      y_offset: result_crop_y_offset(request)
    )
  end

  defp resize_opts(%PipelineRequest{}, opts), do: opts

  defp resize_mode(:fit), do: :fit
  defp resize_mode(:fill), do: :cover
  defp resize_mode(:fill_down), do: :cover
  defp resize_mode(:force), do: :stretch
  defp resize_mode(:auto), do: :auto

  defp imgproxy_resize_dimension(nil), do: {:ok, :auto}
  defp imgproxy_resize_dimension(:auto), do: {:ok, :auto}
  defp imgproxy_resize_dimension({:pixels, 0}), do: {:ok, :auto}

  defp imgproxy_resize_dimension({:pixels, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp imgproxy_resize_dimension({:scale, value}), do: tagged_ratio_from_decimal(value)

  defp imgproxy_tagged_crop_dimension(:auto), do: {:ok, :full_axis}
  defp imgproxy_tagged_crop_dimension({:pixels, 0}), do: {:ok, :full_axis}

  defp imgproxy_tagged_crop_dimension({:pixels, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp imgproxy_tagged_crop_dimension({:scale, value}) do
    tagged_ratio_from_decimal(value)
  end

  defp imgproxy_canvas_dimension(nil), do: {:ok, :auto}
  defp imgproxy_canvas_dimension(:auto), do: {:ok, :auto}
  defp imgproxy_canvas_dimension({:pixels, 0}), do: {:ok, :auto}

  defp imgproxy_canvas_dimension({:pixels, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp imgproxy_canvas_dimension({:scale, value}), do: tagged_ratio_from_decimal(value)

  defp optional_resize_dimension(nil), do: {:ok, nil}
  defp optional_resize_dimension({:pixels, 0}), do: {:ok, :auto}
  defp optional_resize_dimension(dimension), do: imgproxy_resize_dimension(dimension)

  defp resize_guide({:anchor, :center, :center}), do: {:ok, :center}
  defp resize_guide({:anchor, x, y}), do: {:ok, {:anchor, x, y}}

  defp resize_guide({:fp, x, y}) do
    with {:ok, x} <- tagged_ratio_from_decimal(x),
         {:ok, y} <- tagged_ratio_from_decimal(y) do
      {:ok, {:focal, x, y}}
    end
  end

  defp tagged_gravity({:anchor, x, y}), do: {:ok, crop_anchor_guide(x, y)}

  defp tagged_gravity({:fp, x, y}) do
    with {:ok, x} <- tagged_ratio_from_decimal(x),
         {:ok, y} <- tagged_ratio_from_decimal(y) do
      {:ok, {:focal, x, y}}
    end
  end

  defp canvas_placement({:anchor, x, y}), do: {:ok, crop_anchor_guide(x, y)}

  defp canvas_placement({:fp, x, y}) do
    with {:ok, x} <- tagged_ratio_from_decimal(x),
         {:ok, y} <- tagged_ratio_from_decimal(y) do
      {:ok, {:focal, x, y}}
    end
  end

  defp tagged_ratio_from_decimal(value) do
    with {:ok, {numerator, denominator}} <- decimal_ratio_parts(value) do
      gcd = Integer.gcd(numerator, denominator)
      {:ok, {:ratio, div(numerator, gcd), div(denominator, gcd)}}
    end
  end

  defp crop_anchor_guide(:center, :center), do: :center
  defp crop_anchor_guide(:left, :top), do: :top_left
  defp crop_anchor_guide(:center, :top), do: :top
  defp crop_anchor_guide(:right, :top), do: :top_right
  defp crop_anchor_guide(:left, :center), do: :left
  defp crop_anchor_guide(:right, :center), do: :right
  defp crop_anchor_guide(:left, :bottom), do: :bottom_left
  defp crop_anchor_guide(:center, :bottom), do: :bottom
  defp crop_anchor_guide(:right, :bottom), do: :bottom_right

  defp enlargement(%PipelineRequest{resizing_type: :fill_down}), do: :deny
  defp enlargement(%PipelineRequest{enlarge: true}), do: :allow
  defp enlargement(%PipelineRequest{}), do: :deny

  defp build_operation_list({:ok, operation}), do: {:ok, [operation]}

  defp valid_gravity?({:fp, x, y}) do
    is_number(x) and is_number(y) and x >= 0.0 and x <= 1.0 and y >= 0.0 and y <= 1.0
  end

  defp valid_gravity?({:anchor, x, y}) do
    x in [:left, :center, :right] and y in [:top, :center, :bottom]
  end

  defp valid_gravity?(_gravity), do: false

  # Parser values are already floats for decimal syntax. Preserve the decimal
  # spelling Elixir prints for compatibility, instead of materializing the raw
  # IEEE-754 fraction.
  defp decimal_ratio_parts(value) when is_integer(value) and value >= 0, do: {:ok, {value, 1}}

  defp decimal_ratio_parts(value) when is_float(value) and value >= 0.0 do
    value
    |> :erlang.float_to_binary([:compact, decimals: 12])
    |> decimal_string_ratio()
  end

  defp decimal_string_ratio(value) do
    case String.split(value, ".") do
      [integer] ->
        {numerator, ""} = Integer.parse(integer)
        {:ok, {numerator, 1}}

      [integer, fraction_text] ->
        {integer, ""} = Integer.parse(integer)
        {fraction, ""} = Integer.parse(fraction_text)
        denominator = integer_power(10, String.length(fraction_text))
        {:ok, {integer * denominator + fraction, denominator}}
    end
  end

  defp integer_power(base, exponent) do
    Enum.reduce(1..exponent//1, 1, fn _index, product -> product * base end)
  end

  defp missing_dimensions(resizing_type), do: {:error, {:missing_dimensions, resizing_type}}
end
