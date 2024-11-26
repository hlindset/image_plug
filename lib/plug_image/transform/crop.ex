defmodule ImagePlug.Transform.Crop do
  @behaviour ImagePlug.Transform

  alias ImagePlug.TransformState

  defmodule CropParams do
    @doc """
    The parsed parameters used by `ImagePlug.Transform.Crop`.
    """
    defstruct [:width, :height, :crop_from]

    @type int_or_pct() :: {:int, integer()} | {:pct, integer()}
    @type t :: %__MODULE__{
            width: int_or_pct(),
            height: int_or_pct(),
            crop_from: :focus | %{left: int_or_pct(), top: int_or_pct()}
          }
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %CropParams{} = parameters) do
    with coord_mapped_params <- map_params_to_coords(state.image, parameters),
         anchored_params <- anchor_crop(state, coord_mapped_params),
         clamped_params <- clamp(state, anchored_params),
         {:ok, cropped_image} <- crop(state.image, clamped_params) do
      # reset focus to :center on crop
      %ImagePlug.TransformState{state | image: cropped_image, focus: :center}
    else
      {:error, error} ->
        %ImagePlug.TransformState{state | errors: [{__MODULE__, error} | state.errors]}
    end
  end

  defp anchor_crop(%TransformState{}, %{crop_from: %{left: left, top: top}} = params) do
    %{width: params.width, height: params.height, left: left, top: top}
  end

  defp anchor_crop(%TransformState{} = state, %{crop_from: :focus} = params) do
    {center_x, center_y} =
      case state.focus do
        :center ->
          left = Image.width(state.image) / 2
          top = Image.height(state.image) / 2
          {left, top}

        %{left: left, top: top} ->
          {left, top}
      end

    left = center_x - params.width / 2
    top = center_y - params.height / 2

    %{width: params.width, height: params.height, left: round(left), top: round(top)}
  end

  # clamps the crop area to stay withing the image boundaries
  def clamp(%TransformState{image: image}, %{width: width, height: height, top: top, left: left}) do
    clamped_width = min(Image.width(image), width)
    clamped_height = min(Image.height(image), height)
    clamped_left = max(min(Image.width(image) - clamped_width, left), 0)
    clamped_top = max(min(Image.height(image) - clamped_height, top), 0)
    %{width: clamped_width, height: clamped_height, left: clamped_left, top: clamped_top}
  end

  def crop(image, %{width: width, height: height, top: top, left: left}) do
    Image.crop(image, left, top, width, height)
  end

  def to_coord(_size, {:int, int}), do: int
  def to_coord(size, {:pct, pct}), do: round(size * pct / 100)

  def map_params_to_coords(image, %CropParams{
        width: width,
        height: height,
        crop_from: crop_from
      }) do
    %{
      width: to_coord(Image.width(image), width),
      height: to_coord(Image.height(image), height),
      crop_from:
        case crop_from do
          %{left: left, top: top} ->
            %{left: to_coord(Image.width(image), left), top: to_coord(Image.height(image), top)}

          :focus ->
            :focus
        end
    }
  end
end
