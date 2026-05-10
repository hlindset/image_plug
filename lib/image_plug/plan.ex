defmodule ImagePlug.Plan do
  @moduledoc """
  Product-neutral execution request produced by parameter parsers.
  """

  use Boundary,
    top_level?: true,
    deps: [],
    exports: [
      Pipeline,
      Orientation,
      Output,
      Policy,
      Cache,
      Response,
      Response.Filename,
      Source.Plain,
      Operation,
      Operation.CropGuided,
      Operation.CropRegion,
      Operation.Canvas,
      Operation.AutoOrient,
      Operation.Rotate,
      Operation.Flip,
      Operation.ResizeFit,
      Operation.ResizeCover,
      Operation.ResizeStretch,
      Operation.ResizeAuto,
      Geometry.Dimension,
      Geometry.Size,
      Geometry.Region,
      Guide.Gravity
    ]

  alias ImagePlug.Plan.Cache
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Policy
  alias ImagePlug.Plan.Response
  alias ImagePlug.Plan.Response.Filename
  alias ImagePlug.Plan.Source.Plain

  @supported_formats [:avif, :webp, :jpeg, :png]

  @enforce_keys [:source, :pipelines, :output]
  defstruct @enforce_keys ++
              [
                policy: %Policy{},
                cache: %Cache{},
                response: %Response{}
              ]

  @type t :: %__MODULE__{
          source: ImagePlug.Plan.Source.Plain.t(),
          pipelines: [ImagePlug.Plan.Pipeline.t()],
          output: ImagePlug.Plan.Output.t(),
          policy: ImagePlug.Plan.Policy.t(),
          cache: ImagePlug.Plan.Cache.t(),
          response: ImagePlug.Plan.Response.t()
        }

  @type pipeline_error() ::
          :empty_pipeline_plan
          | {:invalid_pipeline_plan, term()}
          | {:invalid_pipeline_operation, term()}

  @type shape_error() ::
          {:unsupported_source, term()}
          | {:invalid_output_plan, term()}
          | {:invalid_policy_plan, term()}
          | {:invalid_cache_plan, term()}
          | {:invalid_response_plan, term()}

  @spec validate_shape(t()) :: {:ok, t()} | {:error, shape_error()}
  def validate_shape(%__MODULE__{} = plan) do
    with :ok <- validate_source(plan.source),
         :ok <- validate_output(plan.output),
         :ok <- validate_policy(plan.policy),
         :ok <- validate_cache(plan.cache),
         :ok <- validate_response(plan.response) do
      {:ok, plan}
    end
  end

  @spec validated_pipelines(t()) :: {:ok, [Pipeline.t()]} | {:error, pipeline_error()}
  def validated_pipelines(%__MODULE__{pipelines: []}), do: {:error, :empty_pipeline_plan}

  def validated_pipelines(%__MODULE__{pipelines: pipelines}) when is_list(pipelines) do
    if Enum.all?(pipelines, &valid_pipeline_shape?/1) do
      validate_pipeline_operations(pipelines)
    else
      {:error, {:invalid_pipeline_plan, pipelines}}
    end
  end

  def validated_pipelines(%__MODULE__{pipelines: pipelines}),
    do: {:error, {:invalid_pipeline_plan, pipelines}}

  defp valid_pipeline_shape?(%Pipeline{operations: operations}) when is_list(operations), do: true
  defp valid_pipeline_shape?(_pipeline), do: false

  defp validate_pipeline_operations(pipelines) do
    case Enum.find_value(pipelines, &invalid_operation/1) do
      nil -> {:ok, pipelines}
      operation -> {:error, {:invalid_pipeline_operation, operation}}
    end
  end

  defp invalid_operation(%Pipeline{operations: operations}) do
    Enum.find(operations, &invalid_operation?/1)
  end

  defp invalid_operation?(%_{}), do: false
  defp invalid_operation?(_operation), do: true

  defp validate_source(%Plain{path: path} = source) do
    if valid_source_path?(path),
      do: :ok,
      else: {:error, {:unsupported_source, source}}
  end

  defp validate_source(source), do: {:error, {:unsupported_source, source}}

  defp valid_source_path?([]), do: true
  defp valid_source_path?([segment | rest]) when is_binary(segment), do: valid_source_path?(rest)
  defp valid_source_path?(_path), do: false

  defp validate_output(%Output{mode: :automatic} = output) do
    validate_output_quality_shape(output)
  end

  defp validate_output(%Output{mode: {:explicit, format}} = output)
       when format in @supported_formats do
    validate_output_quality_shape(output)
  end

  defp validate_output(output), do: {:error, {:invalid_output_plan, output}}

  defp validate_output_quality_shape(output) do
    case validate_output_quality(output) do
      :ok -> :ok
      :error -> {:error, {:invalid_output_plan, output}}
    end
  end

  defp validate_output_quality(%Output{quality: quality, format_qualities: format_qualities})
       when is_map(format_qualities) do
    with :ok <- validate_quality(quality),
         do: validate_format_qualities(format_qualities)
  end

  defp validate_output_quality(_output), do: :error

  defp validate_format_qualities(format_qualities) do
    if Enum.all?(format_qualities, fn {format, quality} ->
         format in @supported_formats and valid_quality?(quality)
       end) do
      :ok
    else
      :error
    end
  end

  defp validate_quality(quality) do
    if valid_quality?(quality), do: :ok, else: :error
  end

  defp valid_quality?(:default), do: true
  defp valid_quality?({:quality, value}) when is_integer(value) and value in 1..100, do: true
  defp valid_quality?(_quality), do: false

  defp validate_policy(%Policy{expires: expires}) when is_integer(expires) and expires >= 0,
    do: :ok

  defp validate_policy(policy), do: {:error, {:invalid_policy_plan, policy}}

  defp validate_cache(%Cache{cachebuster: cachebuster})
       when is_binary(cachebuster) or is_nil(cachebuster),
       do: :ok

  defp validate_cache(cache), do: {:error, {:invalid_cache_plan, cache}}

  defp validate_response(%Response{disposition: disposition, filename: filename} = response)
       when disposition in [:default, :inline, :attachment] do
    if is_nil(filename) or Filename.valid?(filename) do
      :ok
    else
      {:error, {:invalid_response_plan, response}}
    end
  end

  defp validate_response(response), do: {:error, {:invalid_response_plan, response}}
end
