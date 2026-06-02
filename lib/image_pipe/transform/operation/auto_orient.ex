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

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State

  defstruct []

  @type t :: %__MODULE__{}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :auto_orient

  @impl ImagePipe.Transform
  def execute(%__MODULE__{}, %State{} = state) do
    pre_width = Image.width(state.image)

    case Image.autorotate(state.image) do
      {:ok, {image, _flags}} ->
        {:ok, sync_source_dimensions(set_image(state, image), pre_width, Image.width(image))}

      {:error, error} ->
        {:error, {__MODULE__, error}}
    end
  end

  # A 90°/270° auto-rotation swaps the image's width and height. When shrink-on-load
  # has stored the exact original extent for the residual resize, that extent must
  # swap in step so it keeps describing the now-rotated image. A width change is the
  # signal that the axes swapped; 0°/180° and flips leave the width unchanged.
  defp sync_source_dimensions(%State{source_dimensions: {w, h}} = state, pre_width, post_width)
       when post_width != pre_width do
    %State{state | source_dimensions: {h, w}}
  end

  defp sync_source_dimensions(%State{} = state, _pre_width, _post_width), do: state
end
