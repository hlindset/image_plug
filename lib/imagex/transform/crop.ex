defmodule Imagex.Transform.Crop do
  @behaviour Imagex.Transform

  alias Imagex.TransformState
  alias Imagex.Transform.Crop.Parameters

  defp anchor_crop(%TransformState{}, %Parameters{crop_from: %{left: left, top: top}} = params) do
    %{width: params.width, height: params.height, left: left, top: top}
  end

  defp anchor_crop(%TransformState{} = state, %Parameters{crop_from: :focus} = params) do
    {center_x, center_y} =
      case state.focus do
        :center ->
          left = Image.width(state.image) / 2
          top = Image.height(state.image) / 2
          {left, top}

        %{left: left, top: top} ->
          {left, top}
      end

    left = center_x - params.width / 2
    top = center_y - params.height / 2

    %{width: params.width, height: params.height, left: round(left), top: round(top)}
  end

  # clamps the crop area to stay withing the image boundaries
  def clamp(%TransformState{image: image}, %{width: width, height: height, top: top, left: left}) do
    clamped_width = min(Image.width(image), width)
    clamped_height = min(Image.height(image), height)
    clamped_left = max(min(Image.width(image) - clamped_width, left), 0)
    clamped_top = max(min(Image.height(image) - clamped_height, top), 0)
    %{width: clamped_width, height: clamped_height, left: clamped_left, top: clamped_top}
  end

  def crop(image, %{width: width, height: height, top: top, left: left}) do
    Image.crop(image, left, top, width, height)
  end

  def execute(%TransformState{image: image} = state, parameters) do
    with {:ok, parsed_params} <- Parameters.parse(parameters),
         anchored <- anchor_crop(state, parsed_params),
         clamped <- clamp(state, anchored),
         {:ok, cropped_image} <- crop(image, clamped) do
      # reset focus to :center on crop
      %Imagex.TransformState{state | image: cropped_image, focus: :center}
    else
      {:error, error} ->
        %Imagex.TransformState{state | errors: [{__MODULE__, error} | state.errors]}
    end
  end
end
