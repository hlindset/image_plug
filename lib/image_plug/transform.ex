defmodule ImagePlug.Transform do
  alias ImagePlug.TransformState
  alias ImagePlug.ArithmeticParser

  @callback execute(TransformState.t(), String.t()) :: TransformState.t()

  def image_dim(%TransformState{image: image}, :width), do: Image.width(image)
  def image_dim(%TransformState{image: image}, :height), do: Image.height(image)

  @spec to_pixels(TransformState.t(), :width | :height, ImagePlug.imgp_length()) ::
          {:ok, integer()} | {:error, atom()}
  def to_pixels(state, dimension, length)

  def to_pixels(_state, _dimension, {:pixels, num}) do
    {:ok, round(num)}
  end

  def to_pixels(state, dimension, {:scale, numerator, denominator}) do
    {:ok, round(image_dim(state, dimension) * numerator / denominator)}
  end

  def to_pixels(state, dimension, {:percent, num}) do
    {:ok, round(num / 100 * image_dim(state, dimension))}
  end
end
