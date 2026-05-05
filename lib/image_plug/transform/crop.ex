defmodule ImagePlug.Transform.Crop do
  @moduledoc false

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.Geometry.CropCoordinateMapper
  alias ImagePlug.Transform.State

  @default_gravity {:anchor, :center, :center}
  @default_orientation %{auto_orient: false, rotate: 0, flip: nil}

  @doc """
  The parsed operation used by `ImagePlug.Transform.Crop`.
  """
  defstruct [
    :width,
    :height,
    :crop_from,
    gravity: nil,
    x_offset: 0.0,
    y_offset: 0.0,
    orientation: nil
  ]

  @type t :: %__MODULE__{
          width: ImagePlug.imgp_length() | :auto,
          height: ImagePlug.imgp_length() | :auto,
          # Future parser work can output focus + crop actions instead of this special crop_from handling.
          crop_from:
            :focus | :gravity | %{left: ImagePlug.imgp_length(), top: ImagePlug.imgp_length()},
          gravity:
            {:anchor, :left | :center | :right, :top | :center | :bottom}
            | {:fp, float(), float()}
            | nil,
          x_offset: number(),
          y_offset: number(),
          orientation: map() | struct() | nil
        }

  @impl ImagePlug.Transform
  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    exception in [ArgumentError, KeyError] ->
      {:error, exception}
  end

  @impl ImagePlug.Transform
  def new!(%__MODULE__{} = operation) do
    operation
    |> Map.from_struct()
    |> validate_attrs!()

    operation
  end

  def new!(attrs) when is_list(attrs) or is_map(attrs) do
    attrs
    |> validate_attrs!()
    |> then(&struct!(__MODULE__, &1))
  end

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :crop

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{} = params, %State{} = state) do
    image_width = image_width(state)
    image_height = image_height(state)

    case crop_coordinates(params, state, image_width, image_height) do
      {:ok, %{left: left, top: top, width: crop_width, height: crop_height}} ->
        case Image.crop(state.image, left, top, crop_width, crop_height) do
          {:ok, cropped_image} -> state |> set_image(cropped_image) |> reset_focus()
          {:error, error} -> add_error(state, {__MODULE__, error})
        end

      {:error, error} ->
        add_error(state, {__MODULE__, error})
    end
  end

  defp crop_coordinates(
         %__MODULE__{crop_from: :gravity} = params,
         %State{},
         image_width,
         image_height
       ) do
    CropCoordinateMapper.map(
      source_width: image_width,
      source_height: image_height,
      crop_width: params.width,
      crop_height: params.height,
      gravity: default_if_nil(params.gravity, @default_gravity),
      x_offset: default_if_nil(params.x_offset, 0.0),
      y_offset: default_if_nil(params.y_offset, 0.0),
      orientation: default_if_nil(params.orientation, @default_orientation)
    )
  end

  defp crop_coordinates(%__MODULE__{} = params, %State{} = state, image_width, image_height) do
    # keep :auto dimensions as is
    target_width = if params.width == :auto, do: image_width, else: params.width
    target_height = if params.height == :auto, do: image_height, else: params.height

    # make sure crop is within image bounds
    crop_width = max(1, min(image_width, to_pixels(image_width, target_width)))
    crop_height = max(1, min(image_height, to_pixels(image_height, target_height)))

    # figure out the crop anchor
    {center_x, center_y} =
      anchor_crop_to_pixels(
        state,
        params.crop_from,
        image_width,
        image_height,
        crop_width,
        crop_height
      )

    # ...and make sure crop still stays within bounds
    left = max(0, min(image_width - crop_width, round(center_x - crop_width / 2)))
    top = max(0, min(image_height - crop_height, round(center_y - crop_height / 2)))

    {:ok, %{left: left, top: top, width: crop_width, height: crop_height}}
  end

  defp default_if_nil(nil, default), do: default
  defp default_if_nil(value, _default), do: value

  defp anchor_crop_to_pixels(
         %State{},
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

  defp anchor_crop_to_pixels(
         %State{} = state,
         :focus,
         image_width,
         image_height,
         _crop_width,
         _crop_height
       ) do
    anchor_to_pixels(state.focus, image_width, image_height)
  end

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)

    validate_keys!(attrs, [
      :width,
      :height,
      :crop_from,
      :gravity,
      :x_offset,
      :y_offset,
      :orientation
    ])

    validate_dimension_or_auto!(:width, Map.fetch!(attrs, :width))
    validate_dimension_or_auto!(:height, Map.fetch!(attrs, :height))
    validate_crop_from!(Map.fetch!(attrs, :crop_from))
    validate_gravity!(Map.get(attrs, :gravity))
    validate_offset!(:x_offset, Map.get(attrs, :x_offset, 0.0))
    validate_offset!(:y_offset, Map.get(attrs, :y_offset, 0.0))
    validate_orientation!(Map.get(attrs, :orientation))

    attrs
  end

  defp validate_keys!(attrs, allowed_keys) do
    unknown_keys = Map.keys(attrs) -- allowed_keys

    if unknown_keys != [] do
      keys = unknown_keys |> Enum.sort_by(&inspect/1) |> Enum.map_join(", ", &inspect/1)
      raise ArgumentError, "unknown crop option(s): #{keys}"
    end
  end

  defp validate_crop_from!(:focus), do: :ok
  defp validate_crop_from!(:gravity), do: :ok

  defp validate_crop_from!(%{left: left, top: top} = crop_from) do
    validate_keys!(crop_from, [:left, :top])
    validate_position!(:crop_from_left, left)
    validate_position!(:crop_from_top, top)
  end

  defp validate_crop_from!(crop_from),
    do: raise(ArgumentError, "invalid crop_from: #{inspect(crop_from)}")

  defp validate_gravity!(nil), do: :ok

  defp validate_gravity!({:fp, x, y})
       when is_number(x) and is_number(y) and x >= 0.0 and x <= 1.0 and y >= 0.0 and
              y <= 1.0,
       do: :ok

  defp validate_gravity!({:anchor, x, y})
       when x in [:left, :center, :right] and y in [:top, :center, :bottom],
       do: :ok

  defp validate_gravity!(gravity),
    do: raise(ArgumentError, "invalid crop gravity: #{inspect(gravity)}")

  defp validate_offset!(_field, value) when is_number(value), do: :ok

  defp validate_offset!(field, value),
    do: raise(ArgumentError, "invalid crop #{field}: #{inspect(value)}")

  defp validate_orientation!(nil), do: :ok

  defp validate_orientation!(%{auto_orient: auto_orient, rotate: rotate, flip: flip})
       when is_boolean(auto_orient) and rotate in [0, 90, 180, 270] and
              flip in [nil, :none, :horizontal, :vertical, :both],
       do: :ok

  defp validate_orientation!(orientation),
    do: raise(ArgumentError, "invalid crop orientation: #{inspect(orientation)}")

  defp validate_dimension_or_auto!(_field, :auto), do: :ok

  defp validate_dimension_or_auto!(field, value), do: validate_dimension!(field, value)

  defp validate_dimension!(_field, value) when is_number(value) and value > 0, do: :ok
  defp validate_dimension!(_field, {:pixels, value}) when is_number(value) and value > 0, do: :ok
  defp validate_dimension!(_field, {:percent, value}) when is_number(value) and value > 0, do: :ok
  defp validate_dimension!(_field, {:scale, value}) when is_number(value) and value > 0, do: :ok

  defp validate_dimension!(_field, {:scale, numerator, denominator})
       when is_number(numerator) and is_number(denominator) and numerator > 0 and denominator > 0,
       do: :ok

  defp validate_dimension!(field, value),
    do: raise(ArgumentError, "invalid crop #{field}: #{inspect(value)}")

  defp validate_position!(_field, value) when is_number(value) and value >= 0, do: :ok
  defp validate_position!(_field, {:pixels, value}) when is_number(value) and value >= 0, do: :ok
  defp validate_position!(_field, {:percent, value}) when is_number(value) and value >= 0, do: :ok
  defp validate_position!(_field, {:scale, value}) when is_number(value) and value >= 0, do: :ok

  defp validate_position!(_field, {:scale, numerator, denominator})
       when is_number(numerator) and is_number(denominator) and numerator >= 0 and denominator > 0,
       do: :ok

  defp validate_position!(field, value),
    do: raise(ArgumentError, "invalid crop #{field}: #{inspect(value)}")
end
