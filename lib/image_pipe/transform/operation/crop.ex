defmodule ImagePipe.Transform.Operation.Crop do
  @moduledoc """
  Represents an executable crop operation that selects a bounded rectangle
  from the current image.

  ## Construct When

  Transform Plan execution may convert semantic Plan operations to this
  executable operation. Parser modules should construct
  `ImagePipe.Plan.Operation.*` through Plan constructors.

  Use `Crop` for resolved visible crop work, coordinate-based crops, and result
  crops that trim an already resized image back to resolved target geometry.
  Parser-specific gravity inheritance belongs in the parser/adapter layer
  before semantic Plan operations are constructed.

  ## Fields

  Required fields:

  - `width`: crop width as a positive length or `:auto`.
  - `height`: crop height as a positive length or `:auto`.
  - `crop_from`: crop source, either `:gravity` or `%{left: left, top: top}`
    with non-negative position lengths.

  Optional fields:

  - `gravity`: `nil`, an anchor tuple
    `{:anchor, :left | :center | :right, :top | :center | :bottom}`, or a
    focal point tuple `{:fp, x, y}` where `x` and `y` are normalized `0.0..1.0`
    coordinates.
  - `x_offset`: horizontal offset as a number, `{:pixels, value}`,
    `{:scale, value}`, `{:scale, numerator, denominator}`, or
    `{:percent, value}`. Defaults to `0.0`.
  - `y_offset`: vertical offset using the same units as `x_offset`. Defaults
    to `0.0`.
  - `offset_scale`: multiplier applied to pixel offsets, usually the effective
    DPR used by the preceding resize. Defaults to `1.0`.

  Numeric length units are resolved against the current image dimensions during
  execution. `:auto` crop dimensions resolve to the current image dimension on
  that axis.

  ## Execution Semantics

  `execute/2` crops `ImagePipe.Transform.State.image` and returns a state with
  the cropped image. If coordinate mapping or image cropping fails, execution
  returns `{:error, {__MODULE__, reason}}`.

  For `crop_from: :gravity`, execution resolves crop dimensions against the
  current image, defaulting gravity to center when none is provided. Anchor
  gravity pins the crop to an edge or center. Focal-point gravity centers the
  crop around a normalized current-image point and clamps it into image bounds.

  Result crops are represented as `crop_from: :gravity` with explicit `width`
  and `height`. Pixel offsets are multiplied by `offset_scale`; scale and
  percent offsets are resolved relative to the current image bounds.

  For coordinate crops, `crop_from` is the requested top-left crop position
  before the rectangle is clamped to image bounds.

  ## Examples

      crop = %ImagePipe.Transform.Operation.Crop{
        width: {:pixels, 300},
        height: {:pixels, 200},
        crop_from: :gravity,
        gravity: {:fp, 0.25, 0.75},
        x_offset: {:scale, 0.1},
        y_offset: {:pixels, -12}
      }

  A semantic crop request with focal-point guide may execute as the same kind
  of `Crop` operation. URL grammar and aliases stay in parser documentation.
  """

  @behaviour ImagePipe.Transform

  import ImagePipe.Transform.State, only: [set_image: 2]

  import ImagePipe.Transform.Geometry,
    only: [anchor_to_pixels: 3, image_height: 1, image_width: 1, to_pixels: 2]

  alias ImagePipe.Transform.State

  @default_gravity {:anchor, :center, :center}

  @type length_unit() ::
          integer()
          | float()
          | {:pixels, integer() | float()}
          | {:percent, integer() | float()}
          | {:scale, integer() | float()}
          | {:scale, integer() | float(), integer() | float()}

  @doc """
  The executable operation used by `ImagePipe.Transform.Operation.Crop`.
  """
  defstruct [
    :width,
    :height,
    :crop_from,
    gravity: nil,
    x_offset: 0.0,
    y_offset: 0.0,
    offset_scale: 1.0,
    aspect_ratio: nil,
    enlarge: false
  ]

  @type t :: %__MODULE__{
          width: length_unit() | :auto,
          height: length_unit() | :auto,
          crop_from:
            :gravity
            | %{
                left: length_unit(),
                top: length_unit()
              },
          gravity:
            {:anchor, :left | :center | :right, :top | :center | :bottom}
            | {:fp, float(), float()}
            | nil,
          x_offset: length_unit() | number(),
          y_offset: length_unit() | number(),
          offset_scale: pos_integer() | float(),
          aspect_ratio: nil | {:ratio, pos_integer(), pos_integer()},
          enlarge: boolean()
        }

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :crop

  @impl ImagePipe.Transform
  def execute(%__MODULE__{} = params, %State{} = state) do
    image_width = image_width(state)
    image_height = image_height(state)

    case crop_coordinates(params, state, image_width, image_height) do
      {:ok, %{left: left, top: top, width: crop_width, height: crop_height}} ->
        case Image.crop(state.image, left, top, crop_width, crop_height) do
          {:ok, cropped_image} -> {:ok, set_image(state, cropped_image)}
          {:error, error} -> {:error, {__MODULE__, error}}
        end

      {:error, error} ->
        {:error, {__MODULE__, error}}
    end
  end

  defp crop_coordinates(
         %__MODULE__{crop_from: :gravity} = params,
         %State{},
         image_width,
         image_height
       ) do
    with {:ok, crop} <- crop_dimensions(params, image_width, image_height),
         {:ok, crop_width} <- crop_dimension(crop.width, image_width),
         {:ok, crop_height} <- crop_dimension(crop.height, image_height),
         {crop_width, crop_height} =
           correct_aspect_ratio(
             crop_width,
             crop_height,
             params.aspect_ratio,
             params.enlarge,
             image_width,
             image_height
           ),
         {:ok, gravity} <- crop_gravity(default_if_nil(params.gravity, @default_gravity)),
         {:ok, offset_scale} <- offset_scale(crop.offset_scale),
         {:ok, x_offset} <-
           crop_offset(default_if_nil(params.x_offset, 0.0), image_width, offset_scale),
         {:ok, y_offset} <-
           crop_offset(default_if_nil(params.y_offset, 0.0), image_height, offset_scale) do
      {:ok,
       gravity_crop_coordinates(
         image_width,
         image_height,
         crop_width,
         crop_height,
         gravity,
         x_offset,
         y_offset
       )}
    end
  end

  defp crop_coordinates(%__MODULE__{} = params, %State{}, image_width, image_height) do
    # keep :auto dimensions as is
    target_width = if params.width == :auto, do: image_width, else: params.width
    target_height = if params.height == :auto, do: image_height, else: params.height

    # make sure crop is within image bounds
    crop_width = max(1, min(image_width, to_pixels(image_width, target_width)))
    crop_height = max(1, min(image_height, to_pixels(image_height, target_height)))

    # figure out the crop anchor
    {center_x, center_y} =
      anchor_crop_to_pixels(params.crop_from, image_width, image_height, crop_width, crop_height)

    # ...and make sure crop still stays within bounds
    left = max(0, min(image_width - crop_width, round(center_x - crop_width / 2)))
    top = max(0, min(image_height - crop_height, round(center_y - crop_height / 2)))

    {:ok, %{left: left, top: top, width: crop_width, height: crop_height}}
  end

  defp default_if_nil(nil, default), do: default
  defp default_if_nil(value, _default), do: value

  defp crop_dimensions(%__MODULE__{} = params, _image_width, _image_height) do
    {:ok, %{width: params.width, height: params.height, offset_scale: params.offset_scale}}
  end

  defp gravity_crop_coordinates(
         image_width,
         image_height,
         crop_width,
         crop_height,
         gravity,
         x_offset,
         y_offset
       ) do
    crop_width = max(1, min(image_width, crop_width))
    crop_height = max(1, min(image_height, crop_height))

    {left, top} = gravity_origin(gravity, image_width, image_height, crop_width, crop_height)

    %{
      left: clamp_position(round_ties_to_even(left + x_offset), image_width - crop_width),
      top: clamp_position(round_ties_to_even(top + y_offset), image_height - crop_height),
      width: crop_width,
      height: crop_height
    }
  end

  defp gravity_origin(
         {:anchor, x_anchor, y_anchor},
         image_width,
         image_height,
         crop_width,
         crop_height
       ) do
    {
      anchor_origin(x_anchor, image_width, crop_width),
      anchor_origin(y_anchor, image_height, crop_height)
    }
  end

  defp gravity_origin({:fp, x, y}, image_width, image_height, crop_width, crop_height) do
    {
      x * image_width - crop_width / 2,
      y * image_height - crop_height / 2
    }
  end

  defp anchor_origin(:left, _bounds, _crop), do: 0.0
  defp anchor_origin(:top, _bounds, _crop), do: 0.0
  defp anchor_origin(:center, bounds, crop), do: (bounds - crop + 1) / 2
  defp anchor_origin(:right, bounds, crop), do: bounds - crop
  defp anchor_origin(:bottom, bounds, crop), do: bounds - crop

  defp clamp_position(value, max_value), do: max(0, min(max_value, value))

  defp crop_dimension(:auto, bounds), do: {:ok, bounds}

  defp crop_dimension(value, bounds) when is_integer(value) and value > 0,
    do: {:ok, min(value, bounds)}

  defp crop_dimension(value, bounds) when is_float(value) and value > 0,
    do: {:ok, min(round_ties_to_even(value), bounds)}

  defp crop_dimension({:pixels, value}, bounds), do: crop_dimension(value, bounds)

  defp crop_dimension({:scale, numerator, denominator}, bounds)
       when is_number(numerator) and is_number(denominator) and numerator > 0 and denominator > 0 do
    {:ok, min(round_ties_to_even(bounds * numerator / denominator), bounds)}
  end

  defp crop_dimension({:scale, value}, bounds) when is_number(value) and value > 0 do
    {:ok, min(round_ties_to_even(bounds * value), bounds)}
  end

  defp crop_dimension({:percent, value}, bounds) when is_number(value) and value > 0 do
    {:ok, min(round_ties_to_even(bounds * value / 100), bounds)}
  end

  defp crop_dimension(value, _bounds), do: {:error, {:invalid_crop_dimension, value}}

  defp crop_offset(value, _bounds, _offset_scale) when is_number(value), do: {:ok, value}

  defp crop_offset({:scale, numerator, denominator}, bounds, _offset_scale)
       when is_number(numerator) and is_number(denominator) and denominator != 0 do
    {:ok, bounds * numerator / denominator}
  end

  defp crop_offset({:scale, value}, bounds, _offset_scale) when is_number(value),
    do: {:ok, bounds * value}

  defp crop_offset({:percent, value}, bounds, _offset_scale) when is_number(value),
    do: {:ok, bounds * value / 100}

  defp crop_offset({:pixels, value}, _bounds, offset_scale) when is_number(value),
    do: {:ok, value * offset_scale}

  defp crop_offset(value, _bounds, _offset_scale), do: {:error, {:invalid_crop_offset, value}}

  defp offset_scale(value) when is_number(value) and value > 0, do: {:ok, value * 1.0}
  defp offset_scale(value), do: {:error, {:invalid_crop_offset_scale, value}}

  defp crop_gravity({:anchor, x, y} = gravity)
       when x in [:left, :center, :right] and y in [:top, :center, :bottom],
       do: {:ok, gravity}

  defp crop_gravity({:fp, x, y} = gravity)
       when is_number(x) and is_number(y) and x >= 0.0 and x <= 1.0 and y >= 0.0 and y <= 1.0,
       do: {:ok, gravity}

  defp crop_gravity(value), do: {:error, {:invalid_crop_gravity, value}}

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

  defp anchor_crop_to_pixels(
         %{left: left, top: top},
         image_width,
         image_height,
         crop_width,
         crop_height
       ) do
    # if explicit coordinates are given, they are to be the top-left corner of the crop,
    # so we need to move the center point based on the crop dimensions
    {left, top} = anchor_to_pixels({:coordinate, left, top}, image_width, image_height)
    center_x = round(left + crop_width / 2)
    center_y = round(top + crop_height / 2)
    {center_x, center_y}
  end

  defp correct_aspect_ratio(width, height, nil, _enlarge, _image_width, _image_height),
    do: {width, height}

  defp correct_aspect_ratio(width, height, {:ratio, numerator, denominator}, enlarge, image_width, image_height) do
    target = numerator / denominator
    current = width / height

    {corrected_width, corrected_height} =
      cond do
        current == target -> {width, height}
        enlarge and current > target -> {width, round_ties_to_even(width / target)}
        enlarge -> {round_ties_to_even(height * target), height}
        current > target -> {round_ties_to_even(height * target), height}
        true -> {width, round_ties_to_even(width / target)}
      end

    clamp_to_bounds(corrected_width, corrected_height, image_width, image_height)
  end

  defp clamp_to_bounds(width, height, image_width, image_height) do
    scale = min(1.0, min(image_width / width, image_height / height))

    width = max(1, min(image_width, round_ties_to_even(width * scale)))
    height = max(1, min(image_height, round_ties_to_even(height * scale)))

    {width, height}
  end
end
