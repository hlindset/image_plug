defmodule ImagePlug.Transform.Crop do
  @moduledoc false

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.State

  @doc """
  The parsed operation used by `ImagePlug.Transform.Crop`.
  """
  defstruct [:width, :height, :crop_from]

  @type t :: %__MODULE__{
          width: ImagePlug.imgp_length(),
          height: ImagePlug.imgp_length(),
          # Future parser work can output focus + crop actions instead of this special crop_from handling.
          crop_from: :focus | %{left: ImagePlug.imgp_length(), top: ImagePlug.imgp_length()}
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
  def name(%__MODULE__{}), do: :crop

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{} = params, %State{} = state) do
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
         %State{},
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
         %State{} = state,
         :focus,
         image_width,
         image_height,
         _crop_width,
         _crop_height
       ) do
    anchor_to_pixels(state.focus, image_width, image_height)
  end

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)

    _width = Map.fetch!(attrs, :width)
    _height = Map.fetch!(attrs, :height)
    validate_crop_from!(Map.fetch!(attrs, :crop_from))

    attrs
  end

  defp validate_crop_from!(:focus), do: :ok

  defp validate_crop_from!(%{left: _left, top: _top}), do: :ok

  defp validate_crop_from!(crop_from),
    do: raise(ArgumentError, "invalid crop_from: #{inspect(crop_from)}")
end
