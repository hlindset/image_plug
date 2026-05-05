defmodule ImagePlug.Transform.Scale do
  @moduledoc false

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.State

  defstruct [:type, :ratio, :width, :height]

  @type t ::
          %__MODULE__{
            type: :ratio,
            ratio: ImagePlug.imgp_ratio()
          }
          | %__MODULE__{
              type: :dimensions,
              width: ImagePlug.imgp_length(),
              height: ImagePlug.imgp_length() | :auto
            }
          | %__MODULE__{
              type: :dimensions,
              width: ImagePlug.imgp_length() | :auto,
              height: ImagePlug.imgp_length()
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
  def name(%__MODULE__{}), do: :scale

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{type: :dimensions, width: :auto, height: height})
      when height != :auto,
      do: %{access: :sequential}

  def metadata(%__MODULE__{type: :dimensions, width: width, height: :auto})
      when width != :auto,
      do: %{access: :sequential}

  def metadata(%__MODULE__{}), do: %{access: :random}

  defp dimensions_for_scale_type(state, %__MODULE__{
         type: :dimensions,
         width: width,
         height: height
       }) do
    width = to_pixels_or_auto(image_width(state), width)
    height = to_pixels_or_auto(image_height(state), height)
    %{width: width, height: height}
  end

  defp dimensions_for_scale_type(
         state,
         %__MODULE__{type: :ratio, ratio: {ratio_width, ratio_height}}
       ) do
    current_area = image_width(state) * image_height(state)
    target_height = :math.sqrt(current_area * ratio_height / ratio_width)
    target_width = target_height * ratio_width / ratio_height
    %{width: round(target_width), height: round(target_height)}
  end

  @impl ImagePlug.Transform
  def execute(%__MODULE__{} = params, %State{} = state) do
    %{width: width, height: height} = dimensions_for_scale_type(state, params)

    case do_scale(state, width, height) do
      {:ok, image} -> state |> set_image(image) |> reset_focus()
      {:error, _reason} = error -> add_error(state, {__MODULE__, error})
    end
  end

  defp do_scale(%State{}, :auto, :auto), do: {:error, {:invalid_scale_dimensions, :auto_auto}}

  defp do_scale(%State{} = state, width, :auto) do
    target_height = round(width / image_width(state) * image_height(state))
    proportional_scale(state, width, target_height)
  end

  defp do_scale(%State{} = state, :auto, height) do
    target_width = round(height / image_height(state) * image_width(state))
    proportional_scale(state, target_width, height)
  end

  defp do_scale(%State{} = state, width, height) do
    if proportional?(state, width, height) and downscale?(state, width, height) do
      proportional_scale(state, width, height)
    else
      width_scale = width / image_width(state)
      height_scale = height / image_height(state)
      Image.resize(state.image, width_scale, vertical_scale: height_scale)
    end
  end

  defp proportional_scale(%State{} = state, width, height) do
    if downscale?(state, width, height) do
      Image.thumbnail(state.image, "#{width}x#{height}", fit: :contain, resize: :down)
    else
      width_scale = width / image_width(state)
      Image.resize(state.image, width_scale)
    end
  end

  defp proportional?(%State{} = state, width, height) do
    original_ratio = image_width(state) / image_height(state)
    target_ratio = width / height
    abs(original_ratio - target_ratio) < 0.001
  end

  defp downscale?(%State{} = state, width, height) do
    width < image_width(state) and height < image_height(state)
  end

  defp to_pixels_or_auto(_length, :auto), do: :auto
  defp to_pixels_or_auto(length, size_unit), do: to_pixels(length, size_unit)

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)

    case Map.fetch!(attrs, :type) do
      :dimensions ->
        validate_keys!(attrs, [:type, :width, :height])
        width = Map.fetch!(attrs, :width)
        height = Map.fetch!(attrs, :height)
        validate_dimension_pair!(width, height)
        attrs

      :ratio ->
        validate_keys!(attrs, [:type, :ratio])
        validate_ratio!(Map.fetch!(attrs, :ratio))
        attrs

      type ->
        raise ArgumentError, "invalid scale type: #{inspect(type)}"
    end
  end

  defp validate_keys!(attrs, allowed_keys) do
    unknown_keys = Map.keys(attrs) -- allowed_keys

    if unknown_keys != [] do
      keys = unknown_keys |> Enum.sort_by(&inspect/1) |> Enum.map_join(", ", &inspect/1)
      raise ArgumentError, "unknown scale option(s): #{keys}"
    end
  end

  defp validate_dimension_pair!(width, height) do
    validate_dimension_or_auto!(:width, width)
    validate_dimension_or_auto!(:height, height)

    if width == :auto and height == :auto do
      raise ArgumentError, "invalid scale dimensions: width and height cannot both be :auto"
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
    do: raise(ArgumentError, "invalid scale #{field}: #{inspect(value)}")

  defp validate_ratio!({width, height})
       when is_number(width) and is_number(height) and width > 0 and height > 0,
       do: :ok

  defp validate_ratio!(ratio),
    do: raise(ArgumentError, "invalid scale ratio: #{inspect(ratio)}")
end
