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
            crop_from: :focus | %{left: ImagePlug.imgp_length(), top: ImagePlug.imgp_length()}
          }
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %CropParams{} = params) do
    # make sure crop is within image bounds
    crop_width = max(1, min(image_width(state), to_pixels(state, :x, params.width)))
    crop_height = max(1, min(image_height(state), to_pixels(state, :y, params.height)))

    # figure out the crop anchor
    {focus_left, focus_top} = anchor_crop(state, params.crop_from, crop_width, crop_height)

    # ...and make sure crop still stays within bounds
    left = max(0, min(image_width(state) - crop_width, focus_left))
    top = max(0, min(image_height(state) - crop_height, focus_top))

    # execute crop
    case Image.crop(state.image, left, top, crop_width, crop_height) do
      {:ok, cropped_image} -> state |> set_image(cropped_image) |> reset_focus()
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end

  defp anchor_crop(%TransformState{} = state, %{left: left, top: top}, _crop_width, _crop_height),
    do: {to_pixels(state, :x, left), to_pixels(state, :y, top)}

  defp anchor_crop(%TransformState{} = state, :focus, crop_width, crop_height) do
    anchor_to_coord(state.focus, %{
      image_width: image_width(state),
      image_height: image_height(state),
      target_width: crop_width,
      target_height: crop_height
    })
  end
end
