defmodule ImagePlug.Transform.Operation.Flip do
  @moduledoc """
  Represents an executable operation that flips the current image on one or
  both axes.

  ## Construct When

  Transform Plan execution may pass this narrow executable primitive through
  unchanged. Parser modules should construct semantic `ImagePlug.Plan.Operation.*`
  through Plan constructors for non-orientation transform intent.

  ## Fields

  Required fields:

  - `axis`: one of `:horizontal`, `:vertical`, or `:both`.

  Semantic planning is responsible for translating dialect-specific booleans,
  tokens, or aliases into one of these product-neutral axis values before Plan
  execution.

  ## Execution Semantics

  `execute/2` flips `ImagePlug.Transform.State.image`, stores the flipped image
  back into state. For `axis: :horizontal` and `axis: :vertical`, execution
  calls `Image.flip/2` with that axis.

  For `axis: :both`, execution performs a horizontal flip followed by a
  vertical flip, then stores the resulting image in state. If any flip fails,
  execution records `{__MODULE__, error}` in the state errors and leaves normal
  error handling to the transform chain.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :random}`. Flipping is not treated as safe for
  optimized sequential source decoding because the transform may need the full
  decoded image to remap pixels.

  ## Examples

      flip = %ImagePlug.Transform.Operation.Flip{axis: :horizontal}
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State

  alias ImagePlug.Transform.State

  defstruct [:axis]

  @type t :: %__MODULE__{axis: :horizontal | :vertical | :both}

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :flip

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{axis: :both}, %State{} = state) do
    with {:ok, image} <- Image.flip(state.image, :horizontal),
         {:ok, image} <- Image.flip(image, :vertical) do
      set_image(state, image)
    else
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end

  def execute(%__MODULE__{axis: axis}, %State{} = state) do
    case Image.flip(state.image, axis) do
      {:ok, image} -> set_image(state, image)
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end
end
