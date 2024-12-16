defmodule ImagePlug.Utils do
  alias ImagePlug.TransformState

  def image_height(%TransformState{image: image}), do: Image.height(image)
  def image_width(%TransformState{image: image}), do: Image.width(image)

  @spec to_pixels(integer(), ImagePlug.imgp_length()) :: integer()
  def to_pixels(length, size_unit)
  def to_pixels(_length, num) when is_integer(num), do: num
  def to_pixels(_length, num) when is_float(num), do: round(num)
  def to_pixels(_length, {:pixels, num}), do: round(num)

  # todo: remove
  def to_pixels(length, {:scale, numerator, denominator}),
    do: round(length * numerator / denominator)

  def to_pixels(length, {:scale, factor}), do: round(length * factor)

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

  def resolve_auto_size(%TransformState{image: image} = state, width, :auto) do
    aspect_ratio = image_height(state) / image_width(state)
    auto_height = round(to_pixels(image_width(state), width) * aspect_ratio)
    {to_pixels(image_width(state), width), auto_height}
  end

  def resolve_auto_size(%TransformState{image: image} = state, :auto, height) do
    aspect_ratio = image_width(state) / image_height(state)
    auto_width = round(to_pixels(image_height(state), height) * aspect_ratio)
    {auto_width, to_pixels(image_height(state), height)}
  end

  def resolve_auto_size(%TransformState{image: image} = state, width, height) do
    {to_pixels(image_width(state), width), to_pixels(image_height(state), height)}
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

  def compose_background(%TransformState{background: []} = state, width, height) do
    Image.new(width, height, color: :white)
  end

  def compose_background(%TransformState{} = state, width, height) do
    handle_result = fn
      {:ok, image}, acc -> {:cont, {:ok, [image | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end

    background_images =
      Enum.reduce_while(state.background, {:ok, []}, fn
        {:rgb, r, g, b}, {:ok, acc} ->
          Image.new(width, height, color: Image.Color.rgb_color!([r, g, b]))
          |> handle_result.(acc)

        {:rgba, r, g, b, a}, {:ok, acc} ->
          Image.new(width, height, color: Image.Color.rgba_color!([r, g, b, a]))
          |> handle_result.(acc)

        {:blur, sigma}, {:ok, acc} ->
          with {:ok, blurred_image} <- Image.blur(state.image, sigma: sigma),
               {:ok, cropped_image} <- Image.thumbnail(blurred_image, width, fit: :contain) do
            Image.write!(blurred_image, "/Users/hlindset/Downloads/blurred.jpg")
            Image.write!(cropped_image, "/Users/hlindset/Downloads/cropped.jpg")

            {:ok, cropped_image}
          else
            {:error, _reason} = error -> error
          end
          |> handle_result.(acc)
      end)

    compose_images = fn base_image, background_images ->
      IO.inspect(base_image, label: :base_image)
      IO.inspect(background_images, label: :background_images)

      case background_images do
        {:ok, image} ->
          Enum.reduce_while(image, {:ok, base_image}, fn background_image, {:ok, acc_image} ->
            case Image.compose(acc_image, background_image) do
              {:ok, composed} -> {:cont, {:ok, composed}}
              {:error, _reason} = error -> {:halt, error}
            end
          end)

        {:error, _reason} = error ->
          error
      end
    end

    with {:ok, base_image} <- Image.new(width, height, color: :transparent),
         {:ok, [composed_bg]} <- compose_images.(base_image, background_images) do
      {:ok, composed_bg}
    end
  end
end
