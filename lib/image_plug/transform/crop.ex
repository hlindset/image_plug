defmodule ImagePlug.Transform.Crop do
  @behaviour ImagePlug.Transform

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
  def execute(%TransformState{} = state, %CropParams{} = parameters) do
    with coord_mapped_params <- map_params_to_pixels(state, parameters),
         anchored_params <- anchor_crop(state, coord_mapped_params),
         clamped_params <- clamp(state, anchored_params),
         {:ok, cropped_image} <- do_crop(state.image, clamped_params) do
      %ImagePlug.TransformState{state | image: cropped_image} |> TransformState.reset_focus()
    else
      {:error, error} ->
        %ImagePlug.TransformState{state | errors: [{__MODULE__, error} | state.errors]}
    end
  end

  defp anchor_crop(%TransformState{}, %{
         crop_from: %{left: left, top: top},
         width: width,
         height: height
       }) do
    %{width: width, height: height, left: left, top: top}
  end

  defp anchor_crop(
         %TransformState{} = state,
         %{crop_from: :focus, width: width, height: height} = params
       ) do
    center_x =
      case state.focus do
        {:anchor, :left, _} -> width / 2
        {:anchor, :center, _} -> Image.width(state.image) / 2
        {:anchor, :right, _} -> Image.width(state.image) - width / 2
        {:coordinate, left, _top} -> left
      end

    center_y =
      case state.focus do
        {:anchor, _, :top} -> height / 2
        {:anchor, _, :center} -> Image.height(state.image) / 2
        {:anchor, _, :bottom} -> Image.height(state.image) - height / 2
        {:coordinate, _left, top} -> top
      end

    left = center_x - width / 2
    top = center_y - height / 2

    %{width: width, height: height, left: round(left), top: round(top)}
  end

  # clamps the crop area to stay withing the image boundaries
  def clamp(%TransformState{image: image}, %{width: width, height: height, top: top, left: left}) do
    clamped_width = max(min(Image.width(image), width), 1)
    clamped_height = max(min(Image.height(image), height), 1)
    clamped_left = max(min(Image.width(image) - clamped_width, left), 0)
    clamped_top = max(min(Image.height(image) - clamped_height, top), 0)
    %{width: clamped_width, height: clamped_height, left: clamped_left, top: clamped_top}
  end

  def do_crop(image, %{width: width, height: height, top: top, left: left}) do
    Image.crop(image, left, top, width, height)
  end

  def map_crop_from_to_pixels(state, %{left: left, top: top}) do
    with {:ok, mapped_left} <- Transform.to_pixels(state, :width, left),
         {:ok, mapped_top} <- Transform.to_pixels(state, :height, top) do
      {:ok, %{left: mapped_left, top: mapped_top}}
    end
  end

  def map_crop_from_to_pixels(_state, :focus), do: {:ok, :focus}

  def map_params_to_pixels(state, %CropParams{width: width, height: height, crop_from: crop_from}) do
    with {:ok, mapped_width} <- Transform.to_pixels(state, :width, width),
         {:ok, mapped_height} <- Transform.to_pixels(state, :height, height),
         {:ok, mapped_crop_from} <- map_crop_from_to_pixels(state, crop_from) do
      %{width: mapped_width, height: mapped_height, crop_from: mapped_crop_from}
    end
  end
end
