defmodule ImagePipe.Transform.Operation.Flip do
  @moduledoc """
  Represents an executable operation that flips the current image on one or
  both axes.

  ## Construct When

  Transform Plan execution creates this executable primitive from semantic
  `ImagePipe.Plan.Operation.Flip` intent. Parser modules should construct
  semantic `ImagePipe.Plan.Operation.*` structs through Plan constructors.

  ## Fields

  Required fields:

  - `axis`: one of `:horizontal`, `:vertical`, or `:both`.

  Semantic planning is responsible for translating dialect-specific booleans,
  tokens, or aliases into one of these product-neutral axis values before Plan
  execution.

  ## Execution Semantics

  `execute/2` flips `ImagePipe.Transform.State.image`, stores the flipped image
  back into state. For `axis: :horizontal` and `axis: :vertical`, execution
  calls `Image.flip/2` with that axis.

  For `axis: :both`, execution performs a horizontal flip followed by a
  vertical flip, then stores the resulting image in state. If any flip fails,
  execution returns `{:error, {__MODULE__, error}}`.

  ## Examples

      flip = %ImagePipe.Transform.Operation.Flip{axis: :horizontal}
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State

  defstruct [:axis]

  @type t :: %__MODULE__{axis: :horizontal | :vertical | :both}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :flip

  @impl ImagePipe.Transform
  def execute(%__MODULE__{axis: :both}, %State{} = state) do
    with {:ok, image} <- Image.flip(state.image, :horizontal),
         {:ok, image} <- Image.flip(image, :vertical) do
      {:ok, set_image(state, image)}
    else
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  def execute(%__MODULE__{axis: axis}, %State{} = state) do
    case Image.flip(state.image, axis) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
end
