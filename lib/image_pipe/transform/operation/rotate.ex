defmodule ImagePipe.Transform.Operation.Rotate do
  @moduledoc """
  Represents an executable operation that rotates the current image by a
  right-angle amount.

  ## Construct When

  Transform Plan execution creates this executable primitive from semantic
  `ImagePipe.Plan.Operation.Rotate` intent. Parser modules should construct
  semantic `ImagePipe.Plan.Operation.*` structs through Plan constructors.

  ## Fields

  Required fields:

  - `angle`: one of `0`, `90`, `180`, or `270`.

  The operation does not normalize arbitrary degree values; semantic planning
  must translate compatible syntax into one of the accepted right-angle values
  before Plan execution.

  ## Execution Semantics

  `execute/2` with `angle: 0` returns the existing
  `ImagePipe.Transform.State` unchanged.

  For `90`, `180`, and `270`, execution calls `Image.rotate/2` for
  `ImagePipe.Transform.State.image` and stores the rotated image back into
  state. If rotation fails, execution returns `{:error, {__MODULE__, error}}`.

  ## Examples

      rotate = %ImagePipe.Transform.Operation.Rotate{angle: 90}
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State

  defstruct [:angle]

  @type t :: %__MODULE__{angle: 0 | 90 | 180 | 270}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :rotate

  @impl ImagePipe.Transform
  def requires_materialization?(%__MODULE__{}), do: true

  @impl ImagePipe.Transform
  def execute(%__MODULE__{angle: 0}, %State{} = state), do: {:ok, state}

  def execute(%__MODULE__{angle: angle}, %State{} = state) do
    case Image.rotate(state.image, angle) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
end
