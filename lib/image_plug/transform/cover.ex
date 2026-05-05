defmodule ImagePlug.Transform.Cover do
  @moduledoc false

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.State

  @doc """
  The parsed operation used by `ImagePlug.Transform.Cover`.
  """
  defstruct [:type, :ratio, :width, :height, :constraint]

  @type t ::
          %__MODULE__{
            type: :ratio,
            ratio: ImagePlug.imgp_ratio()
          }
          | %__MODULE__{
              type: :dimensions,
              width: ImagePlug.imgp_length(),
              height: ImagePlug.imgp_length() | :auto,
              constraint: :none | :min | :max
            }
          | %__MODULE__{
              type: :dimensions,
              width: ImagePlug.imgp_length() | :auto,
              height: ImagePlug.imgp_length(),
              constraint: :none | :min | :max
            }

  @impl ImagePlug.Transform
  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    exception in [ArgumentError, KeyError] ->
      {:error, exception}
  end

  @impl ImagePlug.Transform
  def new!(%__MODULE__{} = operation), do: operation

  def new!(attrs) when is_list(attrs) or is_map(attrs) do
    attrs
    |> validate_attrs!()
    |> then(&struct!(__MODULE__, &1))
  end

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :cover

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(
        %__MODULE__{
          type: :ratio,
          ratio: {ratio_width, ratio_height}
        },
        %State{} = state
      ) do
    # compute target width and height based on the ratio
    image_width = image_width(state)
    image_height = image_height(state)

    target_ratio = ratio_width / ratio_height
    original_ratio = image_width / image_height

    {target_width, target_height} =
      if original_ratio > target_ratio do
        # wider image: scale height to match ratio
        {round(image_height * target_ratio), image_height}
      else
        # taller image: scale width to match ratio
        {image_width, round(image_width / target_ratio)}
      end

    execute(
      %__MODULE__{
        type: :dimensions,
        width: target_width,
        height: target_height,
        constraint: :none
      },
      state
    )
  end

  @impl ImagePlug.Transform
  def execute(
        %__MODULE__{
          type: :dimensions,
          width: width,
          height: height,
          constraint: constraint
        },
        %State{} = state
      ) do
    {requested_crop_width, requested_crop_height} = resolve_auto_size(state, width, height)
    {resize_width, resize_height} = fit_cover(state, requested_crop_width, requested_crop_height)

    with {:ok, resized_state} <- maybe_scale(state, resize_width, resize_height, constraint),
         {crop_width, crop_height} <-
           fit_crop_to_image(
             requested_crop_width,
             requested_crop_height,
             image_width(resized_state),
             image_height(resized_state)
           ),
         {left, top} <- crop_origin(resized_state, crop_width, crop_height),
         {:ok, cropped_state} <- do_crop(resized_state, left, top, crop_width, crop_height) do
      reset_focus(cropped_state)
    else
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end

  defp fit_cover(%State{} = state, target_width, target_height) do
    # compute aspect ratios
    target_ratio = target_width / target_height
    original_ratio = image_width(state) / image_height(state)

    # determine resize dimensions
    if original_ratio > target_ratio do
      # wider image: scale based on height
      {round(target_height * original_ratio), target_height}
    else
      # taller image: scale based on width
      {target_width, round(target_width / original_ratio)}
    end
  end

  defp fit_crop_to_image(crop_width, crop_height, image_width, image_height) do
    crop_width = max(1, crop_width)
    crop_height = max(1, crop_height)
    scale = min(1.0, min(image_width / crop_width, image_height / crop_height))

    {
      max(1, round(crop_width * scale)),
      max(1, round(crop_height * scale))
    }
  end

  defp crop_origin(%State{} = state, crop_width, crop_height) do
    resized_width = image_width(state)
    resized_height = image_height(state)
    {center_x, center_y} = anchor_to_scale_units(state.focus, resized_width, resized_height)

    scaled_center_x = to_pixels(resized_width, center_x)
    scaled_center_y = to_pixels(resized_height, center_y)

    left = max(0, min(resized_width - crop_width, round(scaled_center_x - crop_width / 2)))
    top = max(0, min(resized_height - crop_height, round(scaled_center_y - crop_height / 2)))

    {left, top}
  end

  defp maybe_scale(%State{} = state, width, height, :min) do
    if width > image_width(state) or height > image_height(state),
      do: do_scale(state, width, height),
      else: {:ok, state}
  end

  defp maybe_scale(%State{} = state, width, height, :max) do
    if width < image_width(state) or height < image_height(state),
      do: do_scale(state, width, height),
      else: {:ok, state}
  end

  defp maybe_scale(image, width, height, _constraint),
    do: do_scale(image, width, height)

  defp do_scale(%State{} = state, width, height) do
    width_scale = width / image_width(state)
    height_scale = height / image_height(state)

    case Image.resize(state.image, width_scale, vertical_scale: height_scale) do
      {:ok, resized_image} -> {:ok, set_image(state, resized_image)}
      {:error, _reason} = error -> error
    end
  end

  defp do_crop(%State{} = state, left, top, width, height) do
    case Image.crop(state.image, left, top, width, height) do
      {:ok, cropped_image} -> {:ok, set_image(state, cropped_image)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)

    case Map.fetch!(attrs, :type) do
      :dimensions ->
        validate_keys!(attrs, [:type, :width, :height, :constraint])
        width = Map.fetch!(attrs, :width)
        height = Map.fetch!(attrs, :height)
        validate_dimension_pair!(width, height)
        validate_constraint!(Map.fetch!(attrs, :constraint))
        attrs

      :ratio ->
        validate_keys!(attrs, [:type, :ratio])
        validate_ratio!(Map.fetch!(attrs, :ratio))
        attrs

      type ->
        raise ArgumentError, "invalid cover type: #{inspect(type)}"
    end
  end

  defp validate_keys!(attrs, allowed_keys) do
    unknown_keys = Map.keys(attrs) -- allowed_keys

    if unknown_keys != [] do
      keys = unknown_keys |> Enum.sort_by(&inspect/1) |> Enum.map_join(", ", &inspect/1)
      raise ArgumentError, "unknown cover option(s): #{keys}"
    end
  end

  defp validate_dimension_pair!(width, height) do
    validate_dimension_or_auto!(:width, width)
    validate_dimension_or_auto!(:height, height)

    if width == :auto and height == :auto do
      raise ArgumentError, "invalid cover dimensions: width and height cannot both be :auto"
    end
  end

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
    do: raise(ArgumentError, "invalid cover #{field}: #{inspect(value)}")

  defp validate_ratio!({width, height})
       when is_number(width) and is_number(height) and width > 0 and height > 0,
       do: :ok

  defp validate_ratio!(ratio),
    do: raise(ArgumentError, "invalid cover ratio: #{inspect(ratio)}")

  defp validate_constraint!(constraint) when constraint in [:none, :min, :max], do: :ok

  defp validate_constraint!(constraint),
    do: raise(ArgumentError, "invalid cover constraint: #{inspect(constraint)}")
end
