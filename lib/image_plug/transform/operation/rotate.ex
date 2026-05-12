defmodule ImagePlug.Transform.Operation.Rotate do
  @moduledoc """
  Represents an executable operation that rotates the current image by a
  right-angle amount.

  ## Construct When

  Parser modules may place this narrow executable primitive directly in
  `ImagePlug.Plan` pipelines when translating compatible orientation syntax.

  ## Fields

  Required fields:

  - `angle`: one of `0`, `90`, `180`, or `270`.

  The operation does not normalize arbitrary degree values; semantic planning
  must translate compatible syntax into one of the accepted right-angle values
  before lowering.

  ## Execution Semantics

  `execute/2` with `angle: 0` returns the existing
  `ImagePlug.Transform.State` unchanged.

  For `90`, `180`, and `270`, execution calls `Image.rotate/2` for
  `ImagePlug.Transform.State.image`, stores the rotated image back into state,
  and resets focus metadata. If rotation fails, execution records
  `{__MODULE__, error}` in the state errors and leaves normal error handling to
  the transform chain.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :random}`. Rotation is not treated as safe for
  optimized sequential source decoding because the transform may need the full
  decoded image to remap pixels and dimensions.

  ## Examples

      rotate = %ImagePlug.Transform.Operation.Rotate{angle: 90}
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State

  alias ImagePlug.Transform.State
  alias ImagePlug.Transform.Validation

  defstruct [:angle]

  @type t :: %__MODULE__{angle: 0 | 90 | 180 | 270}

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :rotate

  @impl ImagePlug.Transform
  def validate(%__MODULE__{angle: angle}) do
    Validation.one_of("rotate", :angle, angle, [0, 90, 180, 270])
  end

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{angle: 0}, %State{} = state), do: state

  def execute(%__MODULE__{angle: angle}, %State{} = state) do
    case Image.rotate(state.image, angle) do
      {:ok, image} -> state |> set_image(image) |> reset_focus()
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end
end
