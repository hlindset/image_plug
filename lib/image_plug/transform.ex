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
      Geometry.CropCoordinateMapper,
      Geometry.DimensionRule,
      Geometry.DimensionResolver,
      Resize,
      AdaptiveResize,
      ExtendCanvas,
      AutoOrient,
      Rotate,
      Flip,
      Scale,
      Cover,
      Contain,
      Crop,
      Focus
    ]

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

  @spec metadata(operation()) :: map()
  def metadata(%module{} = operation) do
    module.metadata(operation)
  end

  @spec execute(operation(), State.t()) :: State.t()
  def execute(%module{} = operation, %State{} = state) do
    module.execute(operation, state)
  end
end
