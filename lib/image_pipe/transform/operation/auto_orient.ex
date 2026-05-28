defmodule ImagePipe.Transform.Operation.AutoOrient do
  @moduledoc """
  Represents an executable operation that applies embedded image
  orientation metadata to the current image pixels.

  ## Construct When

  Transform Plan execution creates this executable primitive from semantic
  `ImagePipe.Plan.Operation.AutoOrient` intent. Parser modules should construct
  semantic `ImagePipe.Plan.Operation.*` structs through Plan constructors.

  ## Fields

  `AutoOrient` has no fields. The source image metadata and pixel data are read
  from `ImagePipe.Transform.State` during execution.

  ## Execution Semantics

  `execute/2` calls `Image.autorotate/1` for
  `ImagePipe.Transform.State.image` and stores the oriented image back into
  state. The image library may return flags describing the orientation work;
  this operation discards those flags because the transform state stores the
  resulting image, not parser-specific orientation metadata.

  If autorotation fails, execution returns `{:error, {__MODULE__, error}}`.

  ## Examples

      auto_orient = %ImagePipe.Transform.Operation.AutoOrient{}
  """

  @behaviour ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State

  defstruct []

  @type t :: %__MODULE__{}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :auto_orient

  @impl ImagePipe.Transform
  def execute(%__MODULE__{}, %State{} = state) do
    case Image.autorotate(state.image) do
      {:ok, {image, _flags}} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
end
