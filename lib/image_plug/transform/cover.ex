defmodule ImagePlug.Transform.Cover do
  @moduledoc """
  Represents a product-neutral cover operation that scales image content to
  cover a requested box or aspect ratio and crops overflow from the result.

  ## Construct When

  Construct `Cover` when parser or planner code needs one operation that
  preserves aspect ratio, ensures the image covers the target geometry, and
  crops the result around the current transform focus. `Cover` is an exported
  standalone operation, not an implementation detail of `Resize`.

  Prefer `Resize` plus a separate result `Crop` when a planner needs the newer
  dimension-rule model or must represent resize and crop as distinct planned
  operations. A future dialect parser may choose `Cover` directly when the
  dialect exposes cover semantics as a single reusable operation.

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
  - `constraint`: `:none`, `:min`, or `:max`.

  At least one dimension must be a positive length; `width: :auto` with
  `height: :auto` is rejected. Positive lengths may be numbers,
  `{:pixels, value}`, `{:percent, value}`, `{:scale, value}`, or
  `{:scale, numerator, denominator}` with positive numeric values and a
  positive denominator.

  For `type: :ratio`, `ratio` is required and must be `{width, height}` with
  positive numeric values.

  ## Execution Semantics

  `execute/2` resolves the requested crop size against the current
  `ImagePlug.Transform.State` image dimensions, computes the smallest
  aspect-preserving resize that covers that crop size, and applies
  `constraint`.

  `constraint: :none` always scales to the cover size. `:min` scales only when
  the cover size would enlarge at least one axis. `:max` scales only when the
  cover size would shrink at least one axis.

  After scaling, the operation crops the image to the requested size, clamped to
  the resized image bounds. The crop is centered on the current transform focus,
  which may have been set by an earlier `Focus` operation, and the crop origin
  is clamped so the rectangle remains inside the image.

  On success, the cropped image is stored in state and focus is reset. Image
  processing failures are added to state as `{ImagePlug.Transform.Cover,
  error}`.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :random}` for every `Cover` operation. Cover
  requires random access because execution may crop any bounded rectangle from
  the resized image and may depend on focus state.

  ## Cache Material

  For `type: :ratio`, material emits:

      [
        op: :cover,
        type: operation.type,
        ratio: operation.ratio
      ]

  For `type: :dimensions`, material emits:

      [
        op: :cover,
        type: operation.type,
        width: operation.width,
        height: operation.height,
        constraint: operation.constraint
      ]

  ## Examples

      {:ok, cover} =
        ImagePlug.Transform.Cover.new(
          type: :dimensions,
          width: {:pixels, 1200},
          height: {:pixels, 630},
          constraint: :none
        )

      poster =
        ImagePlug.Transform.Cover.new!(
          type: :ratio,
          ratio: {2, 3}
        )
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.State
  alias ImagePlug.Transform.Validation

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
  def new!(attrs) when is_list(attrs) or (is_map(attrs) and not is_struct(attrs)) do
    attrs
    |> validate_attrs!()
    |> then(&struct!(__MODULE__, &1))
  end

  def new!(attrs), do: Validation.invalid_options!("cover", attrs)

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
        Validation.keys!(attrs, [:type, :width, :height, :constraint], "cover")
        width = Map.fetch!(attrs, :width)
        height = Map.fetch!(attrs, :height)
        Validation.positive_dimension_pair!("cover", width, height)

        Validation.one_of!("cover", :constraint, Map.fetch!(attrs, :constraint), [
          :none,
          :min,
          :max
        ])

        attrs

      :ratio ->
        Validation.keys!(attrs, [:type, :ratio], "cover")
        Validation.ratio!("cover", :ratio, Map.fetch!(attrs, :ratio))
        attrs

      type ->
        raise ArgumentError, "invalid cover type: #{inspect(type)}"
    end
  end
end
