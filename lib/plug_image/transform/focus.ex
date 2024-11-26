defmodule ImagePlug.Transform.Focus do
  @behaviour ImagePlug.Transform

  alias ImagePlug.TransformState

  defmodule FocusParams do
    @doc """
    The parsed parameters used by `ImagePlug.Transform.Focus`.
    """
    defstruct [:left, :top]

    @type t :: %__MODULE__{left: integer(), top: integer()}
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{image: image} = state, %FocusParams{} = parameters) do
    left_and_top = clamp(state, parameters)
    %ImagePlug.TransformState{state | image: image, focus: left_and_top}
  end

  def clamp(%TransformState{image: image}, %FocusParams{top: top, left: left}) do
    clamped_left = min(Image.width(image), left)
    clamped_top = min(Image.height(image), top)
    %{left: clamped_left, top: clamped_top}
  end
end
