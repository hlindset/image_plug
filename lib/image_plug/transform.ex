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
      Material,
      Types,
      SourceMetadata,
      ResolvedPlan,
      Derivation,
      BackendProfile,
      Resolver,
      Resolver.Geometry,
      Resolver.Lowering,
      Geometry.CropCoordinateMapper,
      Geometry.DimensionRule,
      Geometry.DimensionResolver,
      Operation.Resize,
      Operation.AdaptiveResize,
      Operation.ExtendCanvas,
      Operation.AutoOrient,
      Operation.Rotate,
      Operation.Flip,
      Operation.Scale,
      Operation.Cover,
      Operation.Contain,
      Operation.Crop,
      Operation.Focus
    ]

  alias ImagePlug.Transform.State
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Transform.Material

  @type attrs() :: keyword()
  @type operation() :: struct()

  @callback name(operation()) :: atom()
  @callback validate(operation()) :: :ok | {:error, term()}
  @callback metadata(operation()) :: map()
  @callback execute(operation(), State.t()) :: State.t()

  @spec operation?(term()) :: boolean()
  def operation?(%module{}) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        function_exported?(module, :name, 1) and
          function_exported?(module, :validate, 1) and
          function_exported?(module, :metadata, 1) and
          function_exported?(module, :execute, 2)

      {:error, _reason} ->
        false
    end
  end

  def operation?(_term), do: false

  @spec ensure_operation(term()) :: {:ok, operation()} | {:error, term()}
  def ensure_operation(%module{} = operation) do
    if operation?(operation) do
      {:ok, operation}
    else
      {:error, {:invalid_operation, operation, module}}
    end
  end

  def ensure_operation(operation), do: {:error, {:invalid_operation, operation, :not_a_struct}}

  @spec ensure_operation!(term()) :: operation()
  def ensure_operation!(operation) do
    case ensure_operation(operation) do
      {:ok, operation} ->
        operation

      {:error, {:invalid_operation, %_module{} = operation, module}} ->
        raise ArgumentError,
              "invalid transform operation #{inspect(operation)}: " <>
                "#{inspect(module)} must export name/1, validate/1, metadata/1, and execute/2"

      {:error, {:invalid_operation, operation, :not_a_struct}} ->
        raise ArgumentError,
              "invalid transform operation #{inspect(operation)}: expected an operation struct"
    end
  end

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

  @spec resolve(ImagePlug.Plan.t(), ImagePlug.Transform.SourceMetadata.t(), keyword()) ::
          {:ok, ImagePlug.Transform.ResolvedPlan.t()} | {:error, term()}
  def resolve(
        %ImagePlug.Plan{} = plan,
        %ImagePlug.Transform.SourceMetadata{} = source_metadata,
        opts \\ []
      ) do
    ImagePlug.Transform.Resolver.resolve(plan, source_metadata, opts)
  end

  defp validate_prefetch_safe_pipelines(pipelines) do
    case Enum.find_value(pipelines, &invalid_prefetch_operation/1) do
      nil -> :ok
      operation -> {:error, {:invalid_pipeline_operation, operation}}
    end
  end

  defp invalid_prefetch_operation(%Pipeline{operations: operations}) do
    Enum.find(operations, &invalid_prefetch_operation?/1)
  end

  defp invalid_prefetch_operation?(operation) do
    case validate_prefetch_operation(operation) do
      :ok -> false
      {:error, _reason} -> true
    end
  end

  defp validate_prefetch_operation(operation) do
    cond do
      Operation.semantic?(operation) ->
        Operation.validate_prefetch_safe(operation)

      operation?(operation) ->
        :ok

      Material.impl_for(operation) ->
        :ok

      true ->
        {:error, {:invalid_pipeline_operation, operation}}
    end
  end
end
