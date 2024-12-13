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
              ratio: {ImagePlug.imgp_ratio(), ImagePlug.imgp_ratio()},
              constraint: :regular | :min | :max
            }
            | %__MODULE__{
                type: :dimensions,
                width: ImagePlug.imgp_length(),
                height: ImagePlug.imgp_length() | :auto,
                constraint: :regular | :min | :max
              }
            | %__MODULE__{
                type: :dimensions,
                width: ImagePlug.imgp_length() | :auto,
                height: ImagePlug.imgp_length(),
                constraint: :regular | :min | :max
              }
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %CoverParams{
        width: width,
        height: height,
        constraint: constraint
      }) do
    # convert units to pixels
    target_width = to_pixels(state, :x, width)
    target_height = to_pixels(state, :y, height)

    # figure out width/height
    {resize_width, resize_height} = fit_cover(state, target_width, target_height)

    # calculate focus point based on the resized image size, because we'll be resizing before the crop action
    {focus_left, focus_top} =
      anchor_to_coord(state.focus, %{
        image_width: resize_width,
        image_height: resize_height,
        target_width: target_width,
        target_height: target_height
      })

    # ensure focus_left/focus_top are within bounds
    left = max(0, min(resize_width - target_width, focus_left))
    top = max(0, min(resize_height - target_height, focus_top))

    with {:ok, scaled_state} <-
           maybe_scale(state, %{
             width: resize_width,
             height: resize_height,
             constraint: constraint
           }),
         {:ok, cropped_state} <-
           do_crop(scaled_state, %{
             left: left,
             top: top,
             width: target_width,
             height: target_height
           }) do
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

  def maybe_scale(
        %TransformState{} = state,
        %{width: width, height: height, constraint: :min} = params
      ) do
    if width > image_width(state) or height > image_height(state),
      do: do_scale(state, params),
      else: {:ok, state}
  end

  def maybe_scale(
        %TransformState{} = state,
        %{width: width, height: height, constraint: :max} = params
      ) do
    if width < image_width(state) or height < image_height(state),
      do: do_scale(state, params),
      else: {:ok, state}
  end

  def maybe_scale(image, params), do: do_scale(image, params)

  def do_scale(%TransformState{} = state, %{width: width, height: height}) do
    width_scale = width / image_width(state)
    height_scale = height / image_height(state)

    case Image.resize(state.image, width_scale, vertical_scale: height_scale) do
      {:ok, resized_image} -> {:ok, set_image(state, resized_image)}
      {:error, _reason} = error -> error
    end
  end

  def do_crop(%TransformState{image: image} = state, %{
        width: width,
        height: height,
        top: top,
        left: left
      }) do
    case Image.crop(image, left, top, width, height) do
      {:ok, cropped_image} -> {:ok, set_image(state, cropped_image)}
      {:error, _reason} = error -> error
    end
  end
end
