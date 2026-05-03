defmodule ImagePlug.ParamParser.Native.PlanBuilder do
  @moduledoc false

  alias ImagePlug.OutputPlan
  alias ImagePlug.ParamParser.Native.ParsedRequest
  alias ImagePlug.ParamParser.Native.PipelineRequest
  alias ImagePlug.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.Source.Plain
  alias ImagePlug.Transform

  @default_gravity {:anchor, :center, :center}
  @supported_resizing_types [:fit, :fill, :fill_down, :force, :auto]
  @supported_output_formats [:webp, :avif, :jpeg, :png]

  @spec to_plan(ParsedRequest.t()) :: {:ok, Plan.t()} | {:error, term()}
  def to_plan(%ParsedRequest{} = request) do
    with {:ok, source} <- source_plan(request.source_kind, request.source_path),
         {:ok, pipeline_requests} <- executable_pipeline_requests(request.pipelines),
         :ok <- validate_pipeline_dimensions(pipeline_requests),
         {:ok, output} <- output_plan(request.output_format),
         {:ok, pipelines} <- build_pipelines(pipeline_requests) do
      {:ok,
       %Plan{
         source: source,
         pipelines: pipelines,
         output: output
       }}
    end
  end

  defp source_plan(:plain, path), do: {:ok, %Plain{path: path}}
  defp source_plan(kind, _path), do: {:error, {:unsupported_source_kind, kind}}

  defp executable_pipeline_requests([]), do: {:error, :empty_pipeline_plan}

  defp executable_pipeline_requests(pipeline_requests) when is_list(pipeline_requests) do
    Enum.reduce_while(pipeline_requests, {:ok, []}, fn
      %PipelineRequest{} = pipeline_request, {:ok, valid_pipeline_requests} ->
        {:cont, {:ok, [pipeline_request | valid_pipeline_requests]}}

      value, {:ok, _valid_pipeline_requests} ->
        {:halt, {:error, {:invalid_pipeline_request, value}}}
    end)
    |> case do
      {:ok, valid_pipeline_requests} -> {:ok, Enum.reverse(valid_pipeline_requests)}
      {:error, _reason} = error -> error
    end
  end

  defp executable_pipeline_requests(value), do: {:error, {:invalid_pipeline_request, value}}

  defp validate_pipeline_dimensions(pipeline_requests) do
    pipeline_requests
    |> Enum.map(&validate_dimensions/1)
    |> reduce_validation_results()
  end

  defp build_pipelines([]), do: {:error, :empty_pipeline_plan}

  defp build_pipelines(pipeline_requests) do
    pipeline_requests
    |> Enum.map(&pipeline/1)
    |> reduce_results()
  end

  defp pipeline(%PipelineRequest{} = pipeline_request) do
    with :ok <- validate_dimensions(pipeline_request),
         :ok <- validate_supported_semantics(pipeline_request),
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

  defp reduce_validation_results(results) do
    Enum.reduce_while(results, :ok, fn
      :ok, :ok -> {:cont, :ok}
      {:error, reason}, :ok -> {:halt, {:error, reason}}
    end)
  end

  defp output_plan(nil), do: {:ok, %OutputPlan{mode: :automatic}}
  defp output_plan(:best), do: {:error, {:unsupported_output_format, :best}}

  defp output_plan(format) when format in @supported_output_formats,
    do: {:ok, %OutputPlan{mode: {:explicit, format}}}

  defp output_plan(format), do: {:error, {:invalid_output_format, format}}

  defp validate_dimensions(%PipelineRequest{width: width, height: height}) do
    case validate_dimension(:width, width) do
      :ok -> validate_dimension(:height, height)
      {:error, _reason} = error -> error
    end
  end

  defp validate_dimension(_field, nil), do: :ok

  defp validate_dimension(_field, {:pixels, value}) when is_number(value) and value >= 0,
    do: :ok

  defp validate_dimension(field, value), do: {:error, {:invalid_dimension, field, value}}

  defp validate_supported_semantics(%PipelineRequest{gravity: :sm}),
    do: {:error, {:unsupported_gravity, :sm}}

  defp validate_supported_semantics(%PipelineRequest{resizing_type: resizing_type})
       when resizing_type in [:auto, :fill_down],
       do: {:error, {:unsupported_resizing_type, resizing_type}}

  defp validate_supported_semantics(%PipelineRequest{resizing_type: resizing_type})
       when resizing_type not in @supported_resizing_types,
       do: {:error, {:invalid_resizing_type, resizing_type}}

  defp validate_supported_semantics(%PipelineRequest{enlarge: enlarge})
       when enlarge not in [true, false],
       do: {:error, {:invalid_enlarge, enlarge}}

  defp validate_supported_semantics(%PipelineRequest{gravity: gravity} = request) do
    if valid_gravity?(gravity) do
      validate_extend_semantics(request)
    else
      {:error, {:invalid_gravity, gravity}}
    end
  end

  defp validate_extend_semantics(%PipelineRequest{extend: true}),
    do: {:error, {:unsupported_extend, true}}

  defp validate_extend_semantics(%PipelineRequest{extend_gravity: gravity})
       when not is_nil(gravity),
       do: {:error, {:unsupported_extend_gravity, gravity}}

  defp validate_extend_semantics(%PipelineRequest{extend_x_offset: offset})
       when not is_nil(offset),
       do: {:error, {:unsupported_extend_offset, offset}}

  defp validate_extend_semantics(%PipelineRequest{extend_y_offset: offset})
       when not is_nil(offset),
       do: {:error, {:unsupported_extend_offset, offset}}

  defp validate_extend_semantics(%PipelineRequest{
         gravity_x_offset: x_offset,
         gravity_y_offset: y_offset
       })
       when x_offset != 0.0 or y_offset != 0.0,
       do: {:error, {:unsupported_gravity_offset, {x_offset, y_offset}}}

  defp validate_extend_semantics(%PipelineRequest{}), do: :ok

  defp plan_geometry(%PipelineRequest{resizing_type: :force, width: {:pixels, 0}}),
    do: {:error, {:unsupported_zero_dimension, :force}}

  defp plan_geometry(%PipelineRequest{resizing_type: :force, height: {:pixels, 0}}),
    do: {:error, {:unsupported_zero_dimension, :force}}

  defp plan_geometry(%PipelineRequest{resizing_type: :fill, width: nil, height: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%PipelineRequest{width: nil, height: nil}), do: {:ok, []}

  defp plan_geometry(%PipelineRequest{width: {:pixels, 0}, height: {:pixels, 0}}), do: {:ok, []}

  defp plan_geometry(
         %PipelineRequest{resizing_type: :fit, width: width, height: height} = request
       ) do
    case {normalize_dimension(width), normalize_dimension(height)} do
      {:auto, :auto} -> {:ok, []}
      {planned_width, planned_height} -> {:ok, [contain(planned_width, planned_height, request)]}
    end
  end

  defp plan_geometry(%PipelineRequest{resizing_type: :fill, width: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%PipelineRequest{resizing_type: :fill, height: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%PipelineRequest{resizing_type: :fill} = request) do
    cover =
      cover(normalize_dimension(request.width), normalize_dimension(request.height), request)

    {:ok, maybe_prepend_focus([cover], request.gravity)}
  end

  defp plan_geometry(%PipelineRequest{resizing_type: :force, width: width, height: height}) do
    {:ok, [scale(width || :auto, height || :auto)]}
  end

  defp plan_geometry(%PipelineRequest{resizing_type: resizing_type}),
    do: {:error, {:unsupported_resizing_type, resizing_type}}

  defp scale(width, height) do
    {Transform.Scale,
     %Transform.Scale.ScaleParams{
       type: :dimensions,
       width: width,
       height: height
     }}
  end

  defp contain(width, height, %PipelineRequest{} = request) do
    {Transform.Contain,
     %Transform.Contain.ContainParams{
       type: :dimensions,
       width: width,
       height: height,
       constraint: contain_constraint(request.enlarge),
       letterbox: false
     }}
  end

  defp cover(width, height, %PipelineRequest{} = request) do
    {Transform.Cover,
     %Transform.Cover.CoverParams{
       type: :dimensions,
       width: width,
       height: height,
       constraint: cover_constraint(request.enlarge)
     }}
  end

  defp maybe_prepend_focus(operations, @default_gravity), do: operations

  defp maybe_prepend_focus([{Transform.Cover, _params} | _rest] = operations, gravity) do
    [{Transform.Focus, %Transform.Focus.FocusParams{type: focus_type(gravity)}} | operations]
  end

  defp maybe_prepend_focus(operations, _gravity), do: operations

  defp valid_gravity?({:fp, x, y}) do
    is_number(x) and is_number(y) and x >= 0.0 and x <= 1.0 and y >= 0.0 and y <= 1.0
  end

  defp valid_gravity?({:anchor, x, y}) do
    x in [:left, :center, :right] and y in [:top, :center, :bottom]
  end

  defp valid_gravity?(_gravity), do: false

  defp focus_type({:fp, x, y}), do: {:coordinate, {:percent, x * 100.0}, {:percent, y * 100.0}}
  defp focus_type({:anchor, _x, _y} = gravity), do: gravity

  defp normalize_dimension({:pixels, 0}), do: :auto
  defp normalize_dimension(nil), do: :auto
  defp normalize_dimension(dimension), do: dimension

  defp cover_constraint(true), do: :none
  defp cover_constraint(false), do: :max

  defp contain_constraint(true), do: :regular
  defp contain_constraint(false), do: :max

  defp missing_dimensions(resizing_type), do: {:error, {:missing_dimensions, resizing_type}}
end
