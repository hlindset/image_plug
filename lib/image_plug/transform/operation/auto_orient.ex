defmodule ImagePlug.Transform.Operation.AutoOrient do
  @moduledoc """
  Represents an executable operation that applies embedded image
  orientation metadata to the current image pixels.

  ## Construct When

  Transform Plan execution may pass this narrow executable primitive through
  unchanged. Parser modules should construct semantic `ImagePlug.Plan.Operation.*`
  through Plan constructors for non-orientation transform intent.

  ## Fields

  `AutoOrient` has no fields. The source image metadata and pixel data are read
  from `ImagePlug.Transform.State` during execution.

  ## Execution Semantics

  `execute/2` calls `Image.autorotate/1` for
  `ImagePlug.Transform.State.image` and stores the oriented image back into
  state. The image library may return flags describing the orientation work;
  this operation discards those flags because the transform state stores the
  resulting image, not parser-specific orientation metadata.

  If autorotation fails, execution returns `{:error, {__MODULE__, error}}`.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :sequential}`. Auto-orientation can be used
  with optimized sequential source access because it does not require choosing
  an arbitrary crop rectangle, result crop, canvas expansion, or other
  random-access geometry during decode planning.

  ## Examples

      auto_orient = %ImagePlug.Transform.Operation.AutoOrient{}
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State

  alias ImagePlug.Transform.State

  defstruct []

  @type t :: %__MODULE__{}

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :auto_orient

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :sequential}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{}, %State{} = state) do
    case Image.autorotate(state.image) do
      {:ok, {image, _flags}} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end
end
