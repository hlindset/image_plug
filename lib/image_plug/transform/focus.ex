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
    left = to_pixels(image_width(state), left)
    top = to_pixels(image_height(state), top)

    focus =
      {:coordinate, max(min(image_width(state), left), 0), max(min(image_height(state), top), 0)}

    state
    |> set_focus(focus)
    |> maybe_draw_debug_dot()
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{image: image} = state, %FocusParams{type: {:anchor, x, y}}) do
    state
    |> set_focus({:anchor, x, y})
    |> maybe_draw_debug_dot()
  end

  defp maybe_draw_debug_dot(%TransformState{debug: true, focus: focus} = state) do
    {left, top} = anchor_to_pixels(focus, image_width(state), image_height(state))
    draw_debug_dot(state, left, top)
  end

  defp maybe_draw_debug_dot(state, _focus), do: state
end
