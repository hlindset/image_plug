defmodule ImagePlug.Transform do
  @moduledoc false

  alias ImagePlug.TransformState

  @type attrs() :: keyword() | map()
  @type operation() :: struct()

  @callback new(attrs() | operation()) :: {:ok, operation()} | {:error, term()}
  @callback new!(attrs() | operation()) :: operation()
  @callback name(operation()) :: atom()
  @callback metadata(operation()) :: map()
  @callback execute(operation(), TransformState.t()) :: TransformState.t()

  @spec operation?(term()) :: boolean()
  def operation?(%module{}) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        function_exported?(module, :new, 1) and
          function_exported?(module, :new!, 1) and
          function_exported?(module, :name, 1) and
          function_exported?(module, :metadata, 1) and
          function_exported?(module, :execute, 2)

      {:error, _reason} ->
        false
    end
  end

  def operation?(_term), do: false

  @spec ensure_operation!(term()) :: operation()
  def ensure_operation!(%module{} = operation) do
    if operation?(operation) do
      operation
    else
      raise ArgumentError,
            "invalid transform operation #{inspect(operation)}: " <>
              "#{inspect(module)} must implement ImagePlug.Transform"
    end
  end

  def ensure_operation!(operation) do
    raise ArgumentError,
          "invalid transform operation #{inspect(operation)}: expected an operation struct"
  end

  @spec transform_name(operation()) :: atom()
  def transform_name(operation) do
    %module{} = operation = ensure_operation!(operation)
    module.name(operation)
  end

  @spec metadata(operation()) :: map()
  def metadata(operation) do
    %module{} = operation = ensure_operation!(operation)
    module.metadata(operation)
  end

  @spec execute(operation(), TransformState.t()) :: TransformState.t()
  def execute(operation, %TransformState{} = state) do
    %module{} = operation = ensure_operation!(operation)
    module.execute(operation, state)
  end
end
