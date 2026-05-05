defmodule ImagePlug.Parser.Native.PlanBuilder do
  @moduledoc false

  alias ImagePlug.Parser.Native.ParsedRequest
  alias ImagePlug.Parser.Native.CacheRequest
  alias ImagePlug.Parser.Native.OutputRequest
  alias ImagePlug.Parser.Native.PipelineRequest
  alias ImagePlug.Parser.Native.RequestPolicy
  alias ImagePlug.Parser.Native.ResponseRequest
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Cache
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Policy
  alias ImagePlug.Plan.Response
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform

  @default_gravity {:anchor, :center, :center}
  @supported_resizing_types [:fit, :fill, :fill_down, :force, :auto]
  @supported_output_formats [:webp, :avif, :jpeg, :png]

  @spec to_plan(ParsedRequest.t(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def to_plan(%ParsedRequest{} = request, _opts \\ []) do
    with {:ok, source} <- source_plan(request.source_kind, request.source_path),
         {:ok, pipeline_requests} <- executable_pipeline_requests(request.pipelines),
         :ok <- validate_pipeline_dimensions(pipeline_requests),
         {:ok, output} <- output_plan(request.output),
         {:ok, policy} <- policy_plan(request.policy),
         {:ok, cache} <- cache_plan(request.cache),
         {:ok, response} <- response_plan(request.response),
         {:ok, pipelines} <- build_pipelines(pipeline_requests) do
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

  defp output_plan(%OutputRequest{format: nil} = request) do
    with :ok <- validate_output_qualities(request) do
      {:ok,
       %Output{
         mode: :automatic,
         quality: request.quality,
         format_qualities: request.format_qualities
       }}
    end
  end

  defp output_plan(%OutputRequest{format: :best}),
    do: {:error, {:unsupported_output_format, :best}}

  defp output_plan(%OutputRequest{format: format} = request)
       when format in @supported_output_formats do
    with :ok <- validate_output_qualities(request) do
      {:ok,
       %Output{
         mode: {:explicit, format},
         quality: request.quality,
         format_qualities: request.format_qualities
       }}
    end
  end

  defp output_plan(%OutputRequest{format: format}), do: {:error, {:invalid_output_format, format}}
  defp output_plan(output), do: {:error, {:invalid_output_request, output}}

  defp validate_output_qualities(%OutputRequest{
         quality: quality,
         format_qualities: format_qualities
       }) do
    with :ok <- validate_quality(quality),
         :ok <- validate_format_qualities(format_qualities) do
      :ok
    end
  end

  defp validate_quality(:default), do: :ok
  defp validate_quality({:quality, value}) when is_integer(value) and value in 1..100, do: :ok
  defp validate_quality(value), do: {:error, {:invalid_output_quality, value}}

  defp validate_format_qualities(format_qualities) when is_map(format_qualities) do
    Enum.reduce_while(format_qualities, :ok, fn
      {format, quality}, :ok when format in @supported_output_formats ->
        case validate_quality(quality) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {format, _quality}, :ok ->
        {:halt, {:error, {:unsupported_output_format, format}}}
    end)
  end

  defp validate_format_qualities(format_qualities),
    do: {:error, {:invalid_format_qualities, format_qualities}}

  defp policy_plan(%RequestPolicy{expires: expires}), do: {:ok, %Policy{expires: expires}}
  defp policy_plan(policy), do: {:error, {:invalid_policy_request, policy}}

  defp cache_plan(%CacheRequest{cachebuster: cachebuster}),
    do: {:ok, %Cache{cachebuster: cachebuster}}

  defp cache_plan(cache), do: {:error, {:invalid_cache_request, cache}}

  defp response_plan(%ResponseRequest{filename: filename, disposition: disposition}) do
    {:ok, %Response{filename: filename, disposition: disposition}}
  end

  defp response_plan(response), do: {:error, {:invalid_response_request, response}}

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
      {:auto, :auto} ->
        {:ok, []}

      {planned_width, planned_height} ->
        build_operation_list(contain(planned_width, planned_height, request))
    end
  end

  defp plan_geometry(%PipelineRequest{resizing_type: :fill, width: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%PipelineRequest{resizing_type: :fill, height: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%PipelineRequest{resizing_type: :fill} = request) do
    with {:ok, cover} <-
           cover(normalize_dimension(request.width), normalize_dimension(request.height), request) do
      maybe_prepend_focus([cover], request.gravity)
    end
  end

  defp plan_geometry(%PipelineRequest{resizing_type: :force, width: width, height: height}) do
    build_operation_list(scale(width || :auto, height || :auto))
  end

  defp plan_geometry(%PipelineRequest{resizing_type: resizing_type}),
    do: {:error, {:unsupported_resizing_type, resizing_type}}

  defp scale(width, height) do
    Transform.Scale.new(
      type: :dimensions,
      width: width,
      height: height
    )
  end

  defp contain(width, height, %PipelineRequest{} = request) do
    Transform.Contain.new(
      type: :dimensions,
      width: width,
      height: height,
      constraint: contain_constraint(request.enlarge),
      letterbox: false
    )
  end

  defp cover(width, height, %PipelineRequest{} = request) do
    Transform.Cover.new(
      type: :dimensions,
      width: width,
      height: height,
      constraint: cover_constraint(request.enlarge)
    )
  end

  defp build_operation_list({:ok, operation}), do: {:ok, [operation]}
  defp build_operation_list({:error, _reason} = error), do: error

  defp maybe_prepend_focus(operations, @default_gravity), do: {:ok, operations}

  defp maybe_prepend_focus([operation | _rest] = operations, gravity) do
    if Transform.transform_name(operation) == :cover do
      with {:ok, focus} <- Transform.Focus.new(type: focus_type(gravity)) do
        {:ok, [focus | operations]}
      end
    else
      {:ok, operations}
    end
  end

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
