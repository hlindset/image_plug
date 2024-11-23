defmodule Imagex.Transform.Scale do
  @behaviour Imagex.Transform

  alias Imagex.TransformState
  alias Imagex.Transform.Scale.Parameters

  def execute(%TransformState{image: image} = state, parameters) do
    with {:ok, scale_params} <- Parameters.parse(parameters),
         {:ok, scaled_image} <- do_scale(image, scale_params) do
      # reset focus to :center on scale
      %TransformState{state | image: scaled_image, focus: :center}
    end
  end

  def do_scale(image, %Parameters{width: width, height: :auto}) do
    scale = width / Image.width(image)
    Image.resize(image, scale)
  end

  def do_scale(image, %Parameters{width: :auto, height: height}) do
    scale = height / Image.height(image)
    Image.resize(image, scale)
  end

  def do_scale(image, %Parameters{width: width, height: height}) do
    width_scale = width / Image.width(image)
    height_scale = height / Image.height(image)
    Image.resize(image, width_scale, vertical_scale: height_scale)
  end

  def do_scale(image, _) do
    {:error, :unhandled_scale_parameters}
  end
end
