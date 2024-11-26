defmodule PlugImage.Transform.Focus do
  @behaviour PlugImage.Transform

  alias PlugImage.TransformState
  alias PlugImage.Transform.Focus.Parameters

  def clamp(%TransformState{image: image}, %Parameters{top: top, left: left}) do
    clamped_left = min(Image.width(image), left)
    clamped_top = min(Image.height(image), top)
    %{left: clamped_left, top: clamped_top}
  end

  def execute(%TransformState{image: image} = state, parameters) do
    with {:ok, parsed_parameters} <- Parameters.parse(parameters),
         left_and_top <- clamp(state, parsed_parameters) do
      %PlugImage.TransformState{state | image: image, focus: left_and_top}
    else
      {:error, error} ->
        %PlugImage.TransformState{state | errors: [{__MODULE__, error} | state.errors]}
    end
  end
end
