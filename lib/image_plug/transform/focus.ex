defmodule ImagePlug.Transform.Focus do
  @behaviour ImagePlug.Transform

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  defmodule FocusParams do
    @doc """
    The parsed parameters used by `ImagePlug.Transform.Focus`.
    """
    defstruct [:type]

    @type t ::
            %__MODULE__{type: {:coordinate, ImagePlug.imgp_length(), ImagePlug.imgp_length()}}
            | | %__MODULE__{type: {:anchor, {:center, :center}}
            | | %__MODULE__{type: {:anchor, {:center, :bottom}}
            | | %__MODULE__{type: {:anchor, {:left, :bottom}}
            | | %__MODULE__{type: {:anchor, {:right, :bottom}}
            | | %__MODULE__{type: {:anchor, {:left, :center}}
            | | %__MODULE__{type: {:anchor, {:center, :top}}
            | | %__MODULE__{type: {:anchor, {:left, :top}}
            | | %__MODULE__{type: {:anchor, {:right, :top}}
            | | %__MODULE__{type: {:anchor, {:right, :center}}
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{image: image} = state, %FocusParams{type: {:coordinate, left, top}}) do
    with {:ok, left} <- Transform.to_pixels(state, :width, left),
         {:ok, top} <- Transform.to_pixels(state, :height, top) do
      %ImagePlug.TransformState{
        state
        | image: image,
          focus: {:coordinate, max(min(Image.width(image), left), 0), max(min(Image.height(image), top), 0)}
      }
    else
      {:error, error} ->
        %ImagePlug.TransformState{state | errors: [{__MODULE__, error} | state.errors]}
    end
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{image: image} = state, %FocusParams{type: {:anchor, anchor}}) do
    %ImagePlug.TransformState{ state | image: image, focus: {:anchor, anchor} }
  end
end
