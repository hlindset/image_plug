defmodule ImagePlug.Utils do
  alias ImagePlug.TransformState

  def image_height(%TransformState{image: image}), do: Image.height(image)
  def image_width(%TransformState{image: image}), do: Image.width(image)

  def dim_length(%TransformState{} = state, :x), do: image_width(state)
  def dim_length(%TransformState{} = state, :y), do: image_height(state)

  @spec to_pixels(TransformState.t(), :x | :y, ImagePlug.imgp_length()) :: integer()
  def to_pixels(state, dimension, length)

  def to_pixels(_state, _dimension, {:pixels, num}), do: round(num)

  def to_pixels(state, dimension, {:scale, numerator, denominator}),
    do: round(dim_length(state, dimension) * numerator / denominator)

  def to_pixels(state, dimension, {:percent, num}),
    do: round(num / 100 * dim_length(state, dimension))

  def anchor_to_coord(focus, %{
        image_width: image_width,
        image_height: image_height,
        target_width: target_width,
        target_height: target_height
      }) do
    center_x =
      case focus do
        {:anchor, :left, _} -> 0
        {:anchor, :center, _} -> image_width / 2
        {:anchor, :right, _} -> image_width
        {:coordinate, left, _top} -> left
      end

    center_y =
      case focus do
        {:anchor, _, :top} -> 0
        {:anchor, _, :center} -> image_height / 2
        {:anchor, _, :bottom} -> image_height
        {:coordinate, _left, top} -> top
      end

    {
      round(center_x - target_width / 2),
      round(center_y - target_height / 2)
    }
  end
end
