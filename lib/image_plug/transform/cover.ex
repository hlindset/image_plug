defmodule ImagePlug.Transform.Cover do
  @behaviour ImagePlug.Transform

  import ImagePlug.TransformState
  import ImagePlug.Utils

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  defmodule CoverParams do
    @doc """
    The parsed parameters used by `ImagePlug.Transform.Cover`.
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
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %CoverParams{
        type: :ratio,
        ratio: {ratio_width, ratio_height}
      }) do
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

    execute(state, %CoverParams{
      type: :dimensions,
      width: target_width,
      height: target_height,
      constraint: :none
    })
  end

  @impl ImagePlug.Transform
  def execute(
        %TransformState{} = state,
        %CoverParams{
          width: width,
          height: height,
          constraint: constraint
        } = params
      ) do
    # convert units to pixels
    {crop_width, crop_height} = resolve_auto_size(state, width, height)

    # figure out width/height and get scaled size back
    {resize_width, resize_height} =
      fit_cover(state, crop_width, crop_height)

    # calculate focus scale based on original image and adjust to scaled size
    original_width = image_width(state)
    original_height = image_height(state)
    {center_x, center_y} = anchor_to_scale_units(state.focus, original_width, original_height)

    scaled_center_x = to_pixels(resize_width, center_x)
    scaled_center_y = to_pixels(resize_height, center_y)

    # keep in bounds
    left = max(0, min(resize_width - crop_width, round(scaled_center_x - crop_width / 2)))
    top = max(0, min(resize_height - crop_height, round(scaled_center_y - crop_height / 2)))

    with {:ok, resized_state} <- maybe_scale(state, resize_width, resize_height, constraint),
         {:ok, cropped_state} <- do_crop(resized_state, left, top, crop_width, crop_height) do
      reset_focus(cropped_state)
    else
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end

  def fit_cover(%TransformState{} = state, target_width, target_height) do
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

  def maybe_scale(%TransformState{} = state, width, height, :min) do
    if width > image_width(state) or height > image_height(state),
      do: do_scale(state, width, height),
      else: {:ok, state}
  end

  def maybe_scale(%TransformState{} = state, width, height, :max) do
    if width < image_width(state) or height < image_height(state),
      do: do_scale(state, width, height),
      else: {:ok, state}
  end

  def maybe_scale(image, width, height, _constraint),
    do: do_scale(image, width, height)

  def do_scale(%TransformState{} = state, width, height) do
    width_scale = width / image_width(state)
    height_scale = height / image_height(state)

    case Image.resize(state.image, width_scale, vertical_scale: height_scale) do
      {:ok, resized_image} -> {:ok, set_image(state, resized_image)}
      {:error, _reason} = error -> error
    end
  end

  def do_crop(%TransformState{} = state, left, top, width, height) do
    case Image.crop(state.image, left, top, width, height) do
      {:ok, cropped_image} -> {:ok, set_image(state, cropped_image)}
      {:error, _reason} = error -> error
    end
  end
end
