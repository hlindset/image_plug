defmodule ImagePlug.Transform.Focus do
  @behaviour ImagePlug.Transform

  import ImagePlug.TransformState
  import ImagePlug.Utils

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  defmodule FocusParams do
    @doc """
    The parsed parameters used by `ImagePlug.Transform.Focus`.
    """
    defstruct [:type]

    @type t ::
            %__MODULE__{type: {:coordinate, ImagePlug.imgp_length(), ImagePlug.imgp_length()}}
            | %__MODULE__{type: TransformState.focus_anchor()}
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %FocusParams{type: {:coordinate, left, top}}) do
    left = to_pixels(state, :x, left)
    top = to_pixels(state, :y, top)

    focus =
      {:coordinate,
        max(min(image_width(state), left), 0),
        max(min(image_height(state), top), 0)}

    set_focus(state, focus)
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{image: image} = state, %FocusParams{type: {:anchor, x, y}}) do
    set_focus(state, {:anchor, x, y})
  end
end
