defmodule ImagePlug.Transform.Geometry.CropCoordinateMapper do
  @moduledoc false

  @type mapped_crop :: %{
          left: non_neg_integer(),
          top: non_neg_integer(),
          width: pos_integer(),
          height: pos_integer()
        }

  @spec map(keyword()) :: {:ok, mapped_crop()} | {:error, term()}
  def map(opts) when is_list(opts) do
    with {:ok, source_width} <- positive_integer(opts, :source_width),
         {:ok, source_height} <- positive_integer(opts, :source_height),
         {:ok, orientation} <- orientation(opts[:orientation]),
         {oriented_width, oriented_height} <-
           oriented_bounds(source_width, source_height, orientation),
         {:ok, crop_width} <- dimension(opts[:crop_width], oriented_width),
         {:ok, crop_height} <- dimension(opts[:crop_height], oriented_height),
         {:ok, gravity} <- gravity(opts[:gravity]),
         {:ok, x_offset} <- offset(Keyword.get(opts, :x_offset, 0.0), oriented_width),
         {:ok, y_offset} <- offset(Keyword.get(opts, :y_offset, 0.0), oriented_height) do
      oriented_rect =
        oriented_width
        |> semantic_rect(oriented_height, crop_width, crop_height, gravity, x_offset, y_offset)
        |> invert_flip(oriented_width, oriented_height, orientation.flip)
        |> invert_rotation(source_width, source_height, orientation.rotate)
        |> clamp(source_width, source_height)

      {:ok, oriented_rect}
    end
  end

  def map(opts), do: {:error, {:invalid_crop_mapping_options, opts}}

  defp semantic_rect(
         bounds_width,
         bounds_height,
         crop_width,
         crop_height,
         gravity,
         x_offset,
         y_offset
       ) do
    {left, top} =
      case gravity do
        {:anchor, x_anchor, y_anchor} ->
          {
            anchor_origin(x_anchor, bounds_width, crop_width),
            anchor_origin(y_anchor, bounds_height, crop_height)
          }

        {:fp, x, y} ->
          {
            x * bounds_width - crop_width / 2,
            y * bounds_height - crop_height / 2
          }
      end

    %{
      left: clamp_position(round_ties_to_even(left + x_offset), bounds_width - crop_width),
      top: clamp_position(round_ties_to_even(top + y_offset), bounds_height - crop_height),
      width: crop_width,
      height: crop_height
    }
  end

  defp anchor_origin(:left, _bounds, _crop), do: 0.0
  defp anchor_origin(:top, _bounds, _crop), do: 0.0
  defp anchor_origin(:center, bounds, crop), do: (bounds - crop) / 2
  defp anchor_origin(:right, bounds, crop), do: bounds - crop
  defp anchor_origin(:bottom, bounds, crop), do: bounds - crop

  defp invert_flip(rect, _bounds_width, _bounds_height, flip) when flip in [nil, :none], do: rect

  defp invert_flip(rect, bounds_width, bounds_height, :both) do
    rect
    |> invert_flip(bounds_width, bounds_height, :horizontal)
    |> invert_flip(bounds_width, bounds_height, :vertical)
  end

  defp invert_flip(%{left: left, width: width} = rect, bounds_width, _bounds_height, :horizontal) do
    %{rect | left: bounds_width - left - width}
  end

  defp invert_flip(%{top: top, height: height} = rect, _bounds_width, bounds_height, :vertical) do
    %{rect | top: bounds_height - top - height}
  end

  defp invert_rotation(rect, _source_width, _source_height, 0), do: rect

  defp invert_rotation(
         %{left: left, top: top, width: width, height: height},
         _source_width,
         source_height,
         90
       ) do
    %{left: top, top: source_height - left - width, width: height, height: width}
  end

  defp invert_rotation(
         %{left: left, top: top, width: width, height: height},
         source_width,
         source_height,
         180
       ) do
    %{
      left: source_width - left - width,
      top: source_height - top - height,
      width: width,
      height: height
    }
  end

  defp invert_rotation(
         %{left: left, top: top, width: width, height: height},
         source_width,
         _source_height,
         270
       ) do
    %{left: source_width - top - height, top: left, width: height, height: width}
  end

  defp clamp(%{width: width, height: height} = rect, bounds_width, bounds_height) do
    width = max(1, min(bounds_width, width))
    height = max(1, min(bounds_height, height))

    %{
      left: clamp_position(rect.left, bounds_width - width),
      top: clamp_position(rect.top, bounds_height - height),
      width: width,
      height: height
    }
  end

  defp clamp_position(value, max_value), do: max(0, min(max_value, value))

  defp oriented_bounds(source_width, source_height, %{rotate: rotate}) when rotate in [90, 270],
    do: {source_height, source_width}

  defp oriented_bounds(source_width, source_height, _orientation),
    do: {source_width, source_height}

  defp dimension(:auto, bounds), do: {:ok, bounds}

  defp dimension(value, bounds) when is_integer(value) and value > 0,
    do: {:ok, min(value, bounds)}

  defp dimension(value, bounds) when is_float(value) and value > 0,
    do: {:ok, min(round_ties_to_even(value), bounds)}

  defp dimension({:pixels, value}, bounds), do: dimension(value, bounds)

  defp dimension({:scale, numerator, denominator}, bounds)
       when is_number(numerator) and is_number(denominator) and numerator > 0 and denominator > 0 do
    {:ok, min(round_ties_to_even(bounds * numerator / denominator), bounds)}
  end

  defp dimension({:scale, value}, bounds) when is_number(value) and value > 0 do
    {:ok, min(round_ties_to_even(bounds * value), bounds)}
  end

  defp dimension({:percent, value}, bounds) when is_number(value) and value > 0 do
    {:ok, min(round_ties_to_even(bounds * value / 100), bounds)}
  end

  defp dimension(value, _bounds), do: {:error, {:invalid_crop_dimension, value}}

  defp offset(value, _bounds) when is_number(value), do: {:ok, value}

  defp offset({:scale, numerator, denominator}, bounds)
       when is_number(numerator) and is_number(denominator) and denominator != 0 do
    {:ok, bounds * numerator / denominator}
  end

  defp offset({:scale, value}, bounds) when is_number(value), do: {:ok, bounds * value}
  defp offset({:percent, value}, bounds) when is_number(value), do: {:ok, bounds * value / 100}
  defp offset({:pixels, value}, _bounds) when is_number(value), do: {:ok, value}
  defp offset(value, _bounds), do: {:error, {:invalid_crop_offset, value}}

  defp gravity({:anchor, x, y} = gravity)
       when x in [:left, :center, :right] and y in [:top, :center, :bottom],
       do: {:ok, gravity}

  defp gravity({:fp, x, y} = gravity)
       when is_number(x) and is_number(y) and x >= 0.0 and x <= 1.0 and y >= 0.0 and y <= 1.0,
       do: {:ok, gravity}

  defp gravity(value), do: {:error, {:invalid_crop_gravity, value}}

  defp orientation(nil), do: {:ok, %{auto_orient: false, rotate: 0, flip: :none}}

  defp orientation(%{rotate: rotate} = orientation)
       when rotate in [0, 90, 180, 270] do
    flip = Map.get(orientation, :flip, :none) || :none
    auto_orient = Map.get(orientation, :auto_orient, false)

    cond do
      auto_orient == true ->
        {:error, {:unsupported_crop_orientation, :auto_orient}}

      is_boolean(auto_orient) and flip in [:none, :horizontal, :vertical, :both] ->
        {:ok, %{auto_orient: auto_orient, rotate: rotate, flip: flip}}

      true ->
        {:error, {:invalid_crop_orientation, orientation}}
    end
  end

  defp orientation(value), do: {:error, {:invalid_crop_orientation, value}}

  defp positive_integer(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_crop_source_dimension, key, value}}
      :error -> {:error, {:missing_crop_source_dimension, key}}
    end
  end

  defp round_ties_to_even(value) when is_integer(value), do: value

  defp round_ties_to_even(value) when is_float(value) do
    floor = Float.floor(value)
    fraction = value - floor
    floor = trunc(floor)

    cond do
      fraction < 0.5 -> floor
      fraction > 0.5 -> floor + 1
      rem(floor, 2) == 0 -> floor
      true -> floor + 1
    end
  end
end
