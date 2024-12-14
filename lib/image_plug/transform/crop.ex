defmodule ImagePlug.Transform.Crop do
  @behaviour ImagePlug.Transform

  import ImagePlug.TransformState
  import ImagePlug.Utils

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  defmodule CropParams do
    @doc """
    The parsed parameters used by `ImagePlug.Transform.Crop`.
    """
    defstruct [:width, :height, :crop_from]

    @type t :: %__MODULE__{
            width: ImagePlug.imgp_length(),
            height: ImagePlug.imgp_length(),
            # todo: make the parser output focus + crop actions instead of handling this special crop_from stuff?
            crop_from: :focus | %{left: ImagePlug.imgp_length(), top: ImagePlug.imgp_length()}
          }
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %CropParams{} = params) do
    image_width = image_width(state)
    image_height = image_height(state)

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

    # execute crop
    case Image.crop(state.image, left, top, crop_width, crop_height) do
      {:ok, cropped_image} -> state |> set_image(cropped_image) |> reset_focus()
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end

  defp anchor_crop_to_pixels(
         %TransformState{} = state,
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
         %TransformState{} = state,
         :focus,
         image_width,
         image_height,
         _crop_width,
         _crop_height
       ) do
    anchor_to_pixels(state.focus, image_width, image_height)
  end
end
