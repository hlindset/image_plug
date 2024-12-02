defmodule ImagePlug.Transform.Focus do
  @behaviour ImagePlug.Transform

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  defmodule FocusParams do
    @doc """
    The parsed parameters used by `ImagePlug.Transform.Focus`.
    """
    defstruct [:left, :top]

    @type t :: %__MODULE__{left: ImagePlug.imgp_length(), top: ImagePlug.imgp_length()}
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{image: image} = state, %FocusParams{} = parameters) do
    with {:ok, left} <- Transform.to_pixels(state, :width, parameters.left),
         {:ok, top} <- Transform.to_pixels(state, :height, parameters.top) do
      %ImagePlug.TransformState{
        state
        | image: image,
          focus: %{
            left: max(min(Image.width(image), left), 0),
            top: max(min(Image.height(image), top), 0)
          }
      }
    else
      {:error, error} ->
        %ImagePlug.TransformState{state | errors: [{__MODULE__, error} | state.errors]}
    end
  end
end
