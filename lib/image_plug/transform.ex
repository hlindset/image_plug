defmodule ImagePlug.Transform do
  @moduledoc """
  Behaviour and dispatch facade for transform operations.

  Operation modules implement this behaviour with constructors, metadata, a
  stable transform name, and execution over `ImagePlug.Transform.State`.
  Runtime callers dispatch through this module's generic functions so the
  runtime boundary does not need to know concrete operation modules.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Plan],
    exports: [
      State,
      Chain,
      DecodePlanner,
      Materializer,
      KeyData,
      Types,
      SourceMetadata,
      Geometry.DimensionRule,
      Geometry.DimensionResolver,
      Operation.Resize,
      Operation.ExtendCanvas,
      Operation.AutoOrient,
      Operation.Rotate,
      Operation.Flip,
      Operation.Crop
    ]

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Transform.PlanExecutor
  alias ImagePlug.Transform.SourceMetadata
  alias ImagePlug.Transform.State

  @type attrs() :: keyword()
  @type operation() :: struct()

  @callback name(operation()) :: atom()
  @callback validate(operation()) :: :ok | {:error, term()}
  @callback metadata(operation()) :: map()
  @callback execute(operation(), State.t()) :: State.t()

  @spec transform_name(operation()) :: atom()
  def transform_name(%module{} = operation) do
    module.name(operation)
  end

  @spec validate(operation()) :: :ok | {:error, term()}
  def validate(%module{} = operation) do
    module.validate(operation)
  end

  @spec validate_prefetch_safe_plan(Plan.t()) ::
          {:ok, [Pipeline.t()]} | {:error, term()}
  def validate_prefetch_safe_plan(%Plan{} = plan) do
    with {:ok, %Plan{}} <- Plan.validate_shape(plan),
         {:ok, pipelines} <- Plan.validated_pipelines(plan),
         :ok <- validate_prefetch_safe_pipelines(pipelines) do
      {:ok, pipelines}
    end
  end

  @spec metadata(operation()) :: map()
  def metadata(%module{} = operation) do
    module.metadata(operation)
  end

  @spec execute(operation(), State.t()) :: State.t()
  def execute(%module{} = operation, %State{} = state) do
    module.execute(operation, state)
  end

  @spec execute_plan(Plan.t(), State.t(), SourceMetadata.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def execute_plan(%Plan{} = plan, %State{} = state, %SourceMetadata{} = metadata, opts \\ []) do
    PlanExecutor.execute(plan, state, metadata, opts)
  end

  defp validate_prefetch_safe_pipelines(pipelines) do
    pipelines
    |> Enum.reduce_while(:source, &validate_prefetch_safe_pipeline/2)
    |> case do
      {:error, _reason} = error -> error
      _alignment -> :ok
    end
  end

  defp validate_prefetch_safe_pipeline(%Pipeline{operations: operations}, alignment) do
    case Enum.reduce_while(operations, alignment, &validate_prefetch_safe_operation/2) do
      {:error, _reason} = error -> {:halt, error}
      next_alignment -> {:cont, next_alignment}
    end
  end

  defp validate_prefetch_safe_operation(operation, alignment) do
    case validate_prefetch_operation(operation) do
      :ok -> validate_prefetch_alignment(operation, alignment)
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp validate_prefetch_operation(operation) do
    case Operation.semantic?(operation) do
      true -> Operation.validate_prefetch_safe(operation)
      false -> {:error, {:invalid_pipeline_operation, operation}}
    end
  end

  defp validate_prefetch_alignment(_operation, _alignment), do: {:cont, :current}
end
