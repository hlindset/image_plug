defmodule ImagePlug.Utils do
  alias ImagePlug.TransformState

  def image_height(%TransformState{image: image}), do: Image.height(image)
  def image_width(%TransformState{image: image}), do: Image.width(image)

  @spec to_pixels(integer(), ImagePlug.imgp_length()) :: integer()
  def to_pixels(length, size_unit)
  def to_pixels(_length, num) when is_integer(num), do: num
  def to_pixels(_length, num) when is_float(num), do: round(num)
  def to_pixels(_length, {:pixels, num}), do: round(num)

  def to_pixels(length, {:scale, numerator, denominator}),
    do: round(length * numerator / denominator)

  def to_pixels(length, {:percent, percent}), do: round(percent / 100 * length)

  def anchor_to_scale_units(focus, width, height) do
    center_x_scale =
      case focus do
        {:anchor, :left, _} -> {:scale, 0, 2}
        {:anchor, :center, _} -> {:scale, 1, 2}
        {:anchor, :right, _} -> {:scale, 1, 1}
        {:coordinate, left, _top} -> {:scale, to_pixels(width, left), width}
      end

    center_y_scale =
      case focus do
        {:anchor, _, :top} -> {:scale, 0, 1}
        {:anchor, _, :center} -> {:scale, 1, 2}
        {:anchor, _, :bottom} -> {:scale, 1, 1}
        {:coordinate, _left, top} -> {:scale, to_pixels(height, top), height}
      end

    {center_x_scale, center_y_scale} |> IO.inspect(label: :center_scales)
  end

  def anchor_to_pixels(focus, width, height) do
    {center_x_scale, center_y_scale} = anchor_to_scale_units(focus, width, height)

    {
      to_pixels(width, center_x_scale),
      to_pixels(height, center_y_scale)
    }
  end

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

  def draw_debug_dot(
        %TransformState{} = state,
        left,
        top,
        dot_color \\ :red,
        border_color \\ :white
      ) do
    left = to_pixels(image_width(state), left)
    top = to_pixels(image_height(state), top)

    image_with_debug_dot =
      state.image
      |> Image.Draw.circle!(left, top, 9, color: border_color)
      |> Image.Draw.circle!(left, top, 5, color: dot_color)

    TransformState.set_image(state, image_with_debug_dot)
  end
end
