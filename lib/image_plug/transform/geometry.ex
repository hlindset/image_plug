defmodule ImagePlug.Transform.Geometry do
  @moduledoc false

  alias ImagePlug.Transform.State

  def image_height(%State{image: image}), do: Image.height(image)
  def image_width(%State{image: image}), do: Image.width(image)

  @spec to_pixels(integer(), ImagePlug.Transform.Types.length()) ::
          {:ok, integer()} | {:error, term()}
  def to_pixels(length, size_unit)
  def to_pixels(_length, num) when is_integer(num), do: {:ok, num}
  def to_pixels(_length, num) when is_float(num), do: {:ok, round(num)}
  def to_pixels(_length, {:pixels, num}), do: {:ok, round(num)}
  def to_pixels(length, {:scale, factor}), do: {:ok, round(length * factor)}

  def to_pixels(length, {:scale, numerator, denominator}) when denominator != 0 do
    {:ok, round(length * numerator / denominator)}
  end

  def to_pixels(_length, {:scale, _numerator, 0}), do: {:error, :zero_scale_denominator}

  def to_pixels(length, {:percent, percent}), do: {:ok, round(percent / 100 * length)}

  @spec to_pixels!(integer(), ImagePlug.Transform.Types.length()) :: integer()
  def to_pixels!(length, size_unit) do
    case to_pixels(length, size_unit) do
      {:ok, pixels} ->
        pixels

      {:error, :zero_scale_denominator} ->
        raise ArgumentError, "scale denominator must be non-zero"
    end
  end

  def anchor_to_scale_units(focus, width, height) do
    x_scale =
      case focus do
        {:anchor, :left, _} -> {:scale, 0}
        {:anchor, :center, _} -> {:scale, 0.5}
        {:anchor, :right, _} -> {:scale, 1}
        {:coordinate, left, _top} -> {:scale, to_pixels!(width, left) / width}
      end

    y_scale =
      case focus do
        {:anchor, _, :top} -> {:scale, 0}
        {:anchor, _, :center} -> {:scale, 0.5}
        {:anchor, _, :bottom} -> {:scale, 1}
        {:coordinate, _left, top} -> {:scale, to_pixels!(height, top) / height}
      end

    {x_scale, y_scale}
  end

  def anchor_to_pixels(focus, width, height) do
    case anchor_to_scale_units(focus, width, height) do
      {x_scale, y_scale} ->
        {to_pixels!(width, x_scale), to_pixels!(height, y_scale)}
    end
  end

  def resolve_auto_size(%State{} = state, width, :auto) do
    aspect_ratio = image_height(state) / image_width(state)
    auto_height = round(to_pixels!(image_width(state), width) * aspect_ratio)
    {to_pixels!(image_width(state), width), auto_height}
  end

  def resolve_auto_size(%State{} = state, :auto, height) do
    aspect_ratio = image_width(state) / image_height(state)
    auto_width = round(to_pixels!(image_height(state), height) * aspect_ratio)
    {auto_width, to_pixels!(image_height(state), height)}
  end

  def resolve_auto_size(%State{} = state, width, height) do
    {to_pixels!(image_width(state), width), to_pixels!(image_height(state), height)}
  end

  def draw_debug_dot(
        %State{} = state,
        left,
        top,
        dot_color \\ :red,
        border_color \\ :white
      ) do
    left = to_pixels!(image_width(state), left)
    top = to_pixels!(image_height(state), top)

    image_with_debug_dot =
      state.image
      |> Image.Draw.circle!(left, top, 9, color: border_color)
      |> Image.Draw.circle!(left, top, 5, color: dot_color)

    State.set_image(state, image_with_debug_dot)
  end
end
