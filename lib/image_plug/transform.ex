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
    deps: [],
    exports: [
      State,
      Chain,
      DecodePlanner,
      Materializer,
      Material,
      Types,
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
                "#{inspect(module)} must export name/1, metadata/1, and execute/2"

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

  @spec metadata(operation()) :: map()
  def metadata(%module{} = operation) do
    module.metadata(operation)
  end

  @spec execute(operation(), State.t()) :: State.t()
  def execute(%module{} = operation, %State{} = state) do
    module.execute(operation, state)
  end
end
