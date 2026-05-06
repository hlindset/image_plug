defmodule ImagePlug.Transform.Scale do
  @moduledoc """
  Represents a product-neutral scale operation that changes image dimensions
  either to a requested size or to a requested aspect ratio.

  ## Construct When

  Construct `Scale` when parser or planner code needs a direct scaling
  operation and the source dialect's semantics match this module's behavior.
  `Scale` is an exported standalone operation, not an implementation detail of
  `Resize`.

  Prefer the newer `Resize` operation when the request is a planned fit, fill,
  fill-down, or force resize expressed through a dimension rule. A future
  dialect parser may choose `Scale` directly when its syntax represents
  low-level proportional or non-proportional scaling without `Resize` mode
  semantics.

  ## Construction API

  `new/1` accepts a keyword list or map and returns
  `{:ok, operation}` when all fields are valid. Invalid attributes, missing
  required fields, or unknown keys return `{:error, exception}`.

  `new!/1` accepts the same inputs and returns an operation, raising
  `ArgumentError` or `KeyError` for invalid attributes.

  ## Fields

  For `type: :dimensions`, these fields are required:

  - `width`: positive length or `:auto`.
  - `height`: positive length or `:auto`.

  At least one dimension must be a positive length; `width: :auto` with
  `height: :auto` is rejected. Positive lengths may be numbers,
  `{:pixels, value}`, `{:percent, value}`, `{:scale, value}`, or
  `{:scale, numerator, denominator}` with positive numeric values and a
  positive denominator.

  For `type: :ratio`, `ratio` is required and must be `{width, height}` with
  positive numeric values.

  ## Execution Semantics

  `execute/2` resolves requested lengths against the current
  `ImagePlug.Transform.State` image dimensions. A single `:auto` side is
  derived from the other side while preserving the current aspect ratio.

  Ratio scaling computes target dimensions that preserve the current image area
  while changing to the requested ratio. Dimension scaling resizes to the
  resolved width and height. Proportional downscales use thumbnailing; other
  proportional scales use uniform resize; non-proportional scales resize the
  horizontal and vertical axes independently.

  On success, the scaled image is stored in state and focus is reset. Image
  processing failures are added to state as `{ImagePlug.Transform.Scale,
  error}`.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :sequential}` only for dimension scaling with
  exactly one auto side and one concrete requested side. Ratio scaling and
  fixed two-dimensional scaling return `%{access: :random}`.

  This conservative metadata keeps one-pass sequential decoding limited to the
  dimension cases that are safe for this operation.

  ## Cache Material

  For `type: :ratio`, material emits:

      [
        op: :scale,
        type: operation.type,
        ratio: operation.ratio
      ]

  For `type: :dimensions`, material emits:

      [
        op: :scale,
        type: operation.type,
        width: operation.width,
        height: operation.height
      ]

  ## Examples

      {:ok, scale} =
        ImagePlug.Transform.Scale.new(
          type: :dimensions,
          width: {:pixels, 320},
          height: :auto
        )

      square_ratio =
        ImagePlug.Transform.Scale.new!(
          type: :ratio,
          ratio: {1, 1}
        )
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.State
  alias ImagePlug.Transform.Validation

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
  def new!(attrs) when is_list(attrs) or (is_map(attrs) and not is_struct(attrs)) do
    attrs
    |> validate_attrs!()
    |> then(&struct!(__MODULE__, &1))
  end

  def new!(attrs), do: Validation.invalid_options!("scale", attrs)

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
        Validation.keys!(attrs, [:type, :width, :height], "scale")
        width = Map.fetch!(attrs, :width)
        height = Map.fetch!(attrs, :height)
        Validation.positive_dimension_pair!("scale", width, height)
        attrs

      :ratio ->
        Validation.keys!(attrs, [:type, :ratio], "scale")
        Validation.ratio!("scale", :ratio, Map.fetch!(attrs, :ratio))
        attrs

      type ->
        raise ArgumentError, "invalid scale type: #{inspect(type)}"
    end
  end
end
