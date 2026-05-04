defmodule ImagePlug.Plan do
  @moduledoc """
  Product-neutral execution request produced by parameter parsers.
  """

  alias ImagePlug.Pipeline

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
end
