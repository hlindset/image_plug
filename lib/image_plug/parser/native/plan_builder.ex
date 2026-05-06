defmodule ImagePlug.Parser.Native.PlanBuilder do
  @moduledoc false

  alias ImagePlug.Parser.Native.CacheRequest
  alias ImagePlug.Parser.Native.CropRequest
  alias ImagePlug.Parser.Native.OutputRequest
  alias ImagePlug.Parser.Native.ParsedRequest
  alias ImagePlug.Parser.Native.PipelineRequest
  alias ImagePlug.Parser.Native.RequestPolicy
  alias ImagePlug.Parser.Native.ResponseRequest
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Cache
  alias ImagePlug.Plan.Orientation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Policy
  alias ImagePlug.Plan.Response
  alias ImagePlug.Plan.Response.Filename
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform

  @default_gravity {:anchor, :center, :center}
  @supported_resizing_types [:fit, :fill, :fill_down, :force, :auto]
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
    pipeline_requests
    |> Enum.map(&pipeline/1)
    |> reduce_results()
  end

  defp pipeline(%PipelineRequest{} = pipeline_request) do
    with :ok <- validate_supported_semantics(pipeline_request),
         {:ok, operations} <- plan_geometry(pipeline_request) do
      {:ok, %Pipeline{operations: operations}}
    end
  end

  defp reduce_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, values} -> {:cont, {:ok, [value | values]}}
      {:error, reason}, {:ok, _values} -> {:halt, {:error, reason}}
    end)
    |> case do
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

  defp output_plan(%OutputRequest{format: format}), do: {:error, {:invalid_output_format, format}}
  defp output_plan(output), do: {:error, {:invalid_output_request, output}}

  defp policy_plan(%RequestPolicy{expires: 0}, _opts), do: {:ok, %Policy{expires: 0}}

  defp policy_plan(%RequestPolicy{expires: expires}, opts)
       when is_integer(expires) and expires > 0 do
    with {:ok, now} <- now_unix_seconds(opts),
         :ok <- reject_expired_request(expires, now) do
      {:ok, %Policy{expires: expires}}
    end
  end

  defp policy_plan(%RequestPolicy{expires: expires}, _opts),
    do: {:error, {:invalid_expires, expires}}

  defp policy_plan(policy, _opts), do: {:error, {:invalid_policy_request, policy}}

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

  defp cache_plan(cache), do: {:error, {:invalid_cache_request, cache}}

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

  defp response_plan(response, _source), do: {:error, {:invalid_response_request, response}}

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

  defp validate_supported_semantics(%PipelineRequest{resizing_type: resizing_type})
       when resizing_type not in @supported_resizing_types,
       do: {:error, {:invalid_resizing_type, resizing_type}}

  defp validate_supported_semantics(%PipelineRequest{enlarge: enlarge})
       when enlarge not in [true, false],
       do: {:error, {:invalid_enlarge, enlarge}}

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

  defp validate_crop_semantics(%PipelineRequest{crop: crop}),
    do: {:error, {:invalid_crop_request, crop}}

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

  defp validate_orientation_semantics(%PipelineRequest{orientation: %Orientation{} = orientation}) do
    cond do
      not is_boolean(orientation.auto_orient) ->
        {:error, {:invalid_orientation_auto_orient, orientation.auto_orient}}

      orientation.rotate not in [0, 90, 180, 270] ->
        {:error, {:invalid_orientation_rotate, orientation.rotate}}

      orientation.flip not in [nil, :horizontal, :vertical, :both] ->
        {:error, {:invalid_orientation_flip, orientation.flip}}

      true ->
        :ok
    end
  end

  defp validate_orientation_semantics(%PipelineRequest{orientation: orientation}),
    do: {:error, {:invalid_orientation, orientation}}

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
         {:ok, result_crop_operations} <- result_crop_operations(request, resize_operations),
         {:ok, canvas_operations} <- canvas_operations(request) do
      {:ok,
       orientation_operations ++
         crop_operations ++
         resize_operations ++ result_crop_operations ++ canvas_operations}
    end
  end

  defp crop_operations(%PipelineRequest{crop: nil}), do: {:ok, []}

  defp crop_operations(%PipelineRequest{crop: %CropRequest{} = crop} = request) do
    build_operation_list(
      Transform.Crop.new(
        width: crop.width,
        height: crop.height,
        crop_from: :gravity,
        gravity: crop.gravity || request.gravity,
        x_offset: crop.x_offset,
        y_offset: crop.y_offset
      )
    )
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

  defp auto_orient_operation(%Orientation{auto_orient: true}), do: Transform.AutoOrient.new([])
  defp auto_orient_operation(%Orientation{}), do: nil

  defp rotate_operation(%Orientation{rotate: 0}), do: nil
  defp rotate_operation(%Orientation{rotate: angle}), do: Transform.Rotate.new(angle: angle)

  defp flip_operation(%Orientation{flip: nil}), do: nil
  defp flip_operation(%Orientation{flip: axis}), do: Transform.Flip.new(axis: axis)

  defp result_crop_operations(%PipelineRequest{}, []), do: {:ok, []}

  defp result_crop_operations(
         %PipelineRequest{resizing_type: resizing_type} = request,
         _operations
       )
       when resizing_type in [:fill, :fill_down, :auto] do
    with {:ok, %Transform.Geometry.DimensionRule{} = rule} <- result_crop_rule(request) do
      build_operation_list(
        Transform.Crop.new(
          width: :auto,
          height: :auto,
          crop_from: :gravity,
          gravity: request.gravity,
          x_offset: result_crop_x_offset(request),
          y_offset: result_crop_y_offset(request),
          target_rule: rule
        )
      )
    end
  end

  defp result_crop_operations(%PipelineRequest{}, _operations), do: {:ok, []}

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

  defp result_crop_rule(%PipelineRequest{} = request) do
    with {:ok, %Transform.Geometry.DimensionRule{} = rule} <- dimension_rule(request) do
      {:ok,
       %Transform.Geometry.DimensionRule{
         rule
         | mode: result_crop_rule_mode(request.resizing_type)
       }}
    end
  end

  defp result_crop_rule_mode(:auto), do: :auto
  defp result_crop_rule_mode(mode), do: mode

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
    with {:ok, %Transform.Geometry.DimensionRule{} = rule} <- dimension_rule(request),
         {:ok, operation} <-
           Transform.AdaptiveResize.new(
             rule: %Transform.Geometry.DimensionRule{rule | mode: :auto}
           ) do
      {:ok, [operation]}
    end
  end

  defp resize_operations(%PipelineRequest{resizing_type: resizing_type} = request)
       when resizing_type in [:fit, :fill, :fill_down, :force] do
    resize_from_rule(request)
  end

  defp resize_operations(%PipelineRequest{resizing_type: resizing_type}),
    do: {:error, {:unsupported_resizing_type, resizing_type}}

  defp resize_from_rule(%PipelineRequest{} = request) do
    with {:ok, %Transform.Geometry.DimensionRule{} = rule} <- dimension_rule(request) do
      case {rule.width, rule.height, resize_rule_requested?(request)} do
        {:auto, :auto, false} ->
          {:ok, []}

        {_planned_width, _planned_height, _rule_requested?} ->
          build_operation_list(Transform.Resize.new(rule: rule))
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
      Transform.ExtendCanvas.new(
        rule:
          {:dimensions, normalize_dimension(request.width), normalize_dimension(request.height)},
        gravity: request.extend_gravity || @default_gravity,
        x_offset: request.extend_x_offset || 0.0,
        y_offset: request.extend_y_offset || 0.0,
        background: :white
      )
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
    Transform.ExtendCanvas.new(
      rule: {:aspect_ratio, ratio},
      gravity: @default_gravity,
      x_offset: 0.0,
      y_offset: 0.0,
      background: :white
    )
  end

  defp dimension_rule(%PipelineRequest{} = request) do
    {:ok,
     %Transform.Geometry.DimensionRule{
       mode: dimension_rule_mode(request.resizing_type),
       width: normalize_dimension(request.width),
       height: normalize_dimension(request.height),
       min_width: request.min_width,
       min_height: request.min_height,
       zoom_x: request.zoom_x || 1.0,
       zoom_y: request.zoom_y || 1.0,
       dpr: request.dpr || 1.0,
       enlarge: request.enlarge
     }}
  end

  defp dimension_rule_mode(:fit), do: :fit
  defp dimension_rule_mode(:fill), do: :fill
  defp dimension_rule_mode(:fill_down), do: :fill_down
  defp dimension_rule_mode(:force), do: :force
  defp dimension_rule_mode(:auto), do: :fit

  defp build_operation_list({:ok, operation}), do: {:ok, [operation]}
  defp build_operation_list({:error, _reason} = error), do: error

  defp valid_gravity?({:fp, x, y}) do
    is_number(x) and is_number(y) and x >= 0.0 and x <= 1.0 and y >= 0.0 and y <= 1.0
  end

  defp valid_gravity?({:anchor, x, y}) do
    x in [:left, :center, :right] and y in [:top, :center, :bottom]
  end

  defp valid_gravity?(_gravity), do: false

  defp normalize_dimension({:pixels, 0}), do: :auto
  defp normalize_dimension(nil), do: :auto
  defp normalize_dimension(dimension), do: dimension

  defp missing_dimensions(resizing_type), do: {:error, {:missing_dimensions, resizing_type}}
end
