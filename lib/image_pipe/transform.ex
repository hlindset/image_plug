defmodule ImagePipe.Transform do
  @moduledoc """
  Behaviour and dispatch facade for transform operations.

  Operation modules implement this behaviour with a stable transform name and
  execution over `ImagePipe.Transform.State`. Runtime callers dispatch through
  this module's generic functions so the runtime boundary does not need to know
  concrete operation modules.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Plan, ImagePipe.Telemetry],
    exports: [
      State,
      Chain,
      DecodePlanner,
      Materializer,
      Detector,
      Detector.ImageVision,
      Detector.Warmup,
      Operation.Resize,
      Operation.ExtendCanvas,
      Operation.Padding,
      Operation.Background,
      Operation.AutoOrient,
      Operation.Rotate,
      Operation.Flip,
      Operation.Crop,
      Operation.Blur,
      Operation.Sharpen,
      Operation.Pixelate,
      Operation.Monochrome,
      Operation.Duotone,
      Operation.Brightness,
      Operation.Contrast,
      Operation.Saturation,
      Operation.NormalizeColorProfile
    ]

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Transform.PlanExecutor
  alias ImagePipe.Transform.State

  @type attrs() :: keyword()
  @type operation() :: struct()

  @callback name(operation()) :: atom()
  @callback execute(operation(), State.t()) :: {:ok, State.t()} | {:error, term()}

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

  @spec execute(operation(), State.t()) :: {:ok, State.t()} | {:error, term()}
  def execute(%module{} = operation, %State{} = state) do
    module.execute(operation, state)
  end

  @spec execute_plan(Plan.t(), State.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def execute_plan(%Plan{} = plan, %State{} = state, opts \\ []) do
    PlanExecutor.execute(plan, state, opts)
  end

  @default_detector ImagePipe.Transform.Detector.ImageVision

  @spec resolve_detector(:default | nil | module()) :: module() | nil
  def resolve_detector(:default), do: @default_detector
  def resolve_detector(nil), do: nil
  def resolve_detector(module) when is_atom(module), do: module

  @spec detector_available?(:default | nil | module(), keyword()) :: boolean()
  def detector_available?(detector, opts) do
    case resolve_detector(detector) do
      nil -> false
      module -> module.available?(opts)
    end
  end

  @spec detector_identity(:default | nil | module(), keyword()) :: {module(), term()} | nil
  def detector_identity(detector, opts) do
    case resolve_detector(detector) do
      nil -> nil
      module -> module.identity(opts)
    end
  end
end
