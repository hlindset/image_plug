defmodule ImagePlug.Transform.Geometry do
  @moduledoc false

  alias ImagePlug.Transform.State

  def image_height(%State{image: image}), do: Image.height(image)
  def image_width(%State{image: image}), do: Image.width(image)

  @spec to_pixels(integer(), ImagePlug.Transform.Types.length()) :: integer()
  def to_pixels(length, size_unit)
  def to_pixels(_length, num) when is_integer(num), do: num
  def to_pixels(_length, num) when is_float(num), do: round(num)
  def to_pixels(_length, {:pixels, num}), do: round(num)
  def to_pixels(length, {:scale, factor}), do: round(length * factor)

  def to_pixels(length, {:scale, numerator, denominator}),
    do: round(length * numerator / denominator)

  def to_pixels(length, {:percent, percent}), do: round(percent / 100 * length)

  def anchor_to_scale_units(focus, width, height) do
    x_scale =
      case focus do
        {:anchor, :left, _} -> {:scale, 0}
        {:anchor, :center, _} -> {:scale, 0.5}
        {:anchor, :right, _} -> {:scale, 1}
        {:coordinate, left, _top} -> {:scale, to_pixels(width, left) / width}
      end

    y_scale =
      case focus do
        {:anchor, _, :top} -> {:scale, 0}
        {:anchor, _, :center} -> {:scale, 0.5}
        {:anchor, _, :bottom} -> {:scale, 1}
        {:coordinate, _left, top} -> {:scale, to_pixels(height, top) / height}
      end

    {x_scale, y_scale}
  end

  def anchor_to_pixels(focus, width, height) do
    case anchor_to_scale_units(focus, width, height) do
      {x_scale, y_scale} ->
        {to_pixels(width, x_scale), to_pixels(height, y_scale)}
    end
  end
end
