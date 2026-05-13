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
      Operation.Resize,
      Operation.ExtendCanvas,
      Operation.AutoOrient,
      Operation.Rotate,
      Operation.Flip,
      Operation.Crop
    ]

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Transform.PlanExecutor
  alias ImagePlug.Transform.State

  @type attrs() :: keyword()
  @type operation() :: struct()

  @callback name(operation()) :: atom()
  @callback metadata(operation()) :: map()
  @callback execute(operation(), State.t()) :: State.t()

  @spec transform_name(operation()) :: atom()
  def transform_name(%module{} = operation) do
    module.name(operation)
  end

  @spec validate_prefetch_safe_plan(Plan.t()) ::
          {:ok, [Pipeline.t()]} | {:error, term()}
  def validate_prefetch_safe_plan(%Plan{} = plan) do
    case Plan.validate_shape(plan) do
      {:ok, %Plan{}} -> Plan.validated_pipelines(plan)
      {:error, _reason} = error -> error
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

  @spec execute_plan(Plan.t(), State.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def execute_plan(%Plan{} = plan, %State{} = state, opts \\ []) do
    PlanExecutor.execute(plan, state, opts)
  end
end
