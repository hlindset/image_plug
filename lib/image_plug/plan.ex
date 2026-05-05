defmodule ImagePlug.Plan do
  @moduledoc """
  Product-neutral execution request produced by parameter parsers.
  """

  alias ImagePlug.OutputPlan
  alias ImagePlug.Pipeline
  alias ImagePlug.Source.Plain

  @enforce_keys [:source, :pipelines, :output]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source: ImagePlug.Source.Plain.t(),
          pipelines: [ImagePlug.Pipeline.t()],
          output: ImagePlug.OutputPlan.t()
        }

  @type pipeline_error() ::
          :empty_pipeline_plan
          | {:invalid_pipeline_plan, term()}
          | {:invalid_pipeline_operation, term()}

  @type shape_error() ::
          {:unsupported_source, term()}
          | {:invalid_output_plan, term()}

  @spec validate_shape(t()) :: {:ok, t()} | {:error, shape_error()}
  def validate_shape(%__MODULE__{} = plan) do
    with :ok <- validate_source(plan.source),
         :ok <- validate_output(plan.output) do
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

  defp invalid_operation?({module, _params}) when is_atom(module) do
    not operation_module?(module)
  end

  defp invalid_operation?(_operation), do: true

  defp operation_module?(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> function_exported?(module, :execute, 2)
      {:error, _reason} -> false
    end
  end

  defp validate_source(%Plain{path: path}) when is_list(path) do
    if Enum.all?(path, &is_binary/1),
      do: :ok,
      else: {:error, {:unsupported_source, %Plain{path: path}}}
  end

  defp validate_source(source), do: {:error, {:unsupported_source, source}}

  defp validate_output(%OutputPlan{mode: :automatic}), do: :ok

  defp validate_output(%OutputPlan{mode: {:explicit, format}})
       when format in [:avif, :webp, :jpeg, :png],
       do: :ok

  defp validate_output(output), do: {:error, {:invalid_output_plan, output}}
end
