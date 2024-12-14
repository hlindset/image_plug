defmodule ImagePlug.Transform.Scale do
  @behaviour ImagePlug.Transform

  import ImagePlug.TransformState
  import ImagePlug.Utils

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  defmodule ScaleParams do
    defstruct [:type, :ratio, :width, :height]

    @type t ::
            %__MODULE__{
              type: :ratio,
              ratio: {ImagePlug.imgp_ratio(), ImagePlug.imgp_ratio()}
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
  end

  defp dimensions_for_scale_type(state, %ScaleParams{
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
         %ScaleParams{type: :ratio, ratio: {ratio_width, ratio_height}} = params
       ) do
    current_area = image_width(state) * image_height(state)
    target_height = :math.sqrt(current_area * ratio_height / ratio_width)
    target_width = target_height * ratio_width / ratio_height
    %{width: round(target_width), height: round(target_height)}
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %ScaleParams{} = params) do
    %{width: width, height: height} = dimensions_for_scale_type(state, params)

    case do_scale(state, width, height) do
      {:ok, image} -> state |> set_image(image) |> reset_focus()
      {:error, _reason} = error -> add_error(state, {__MODULE__, error})
    end
  end

  def do_scale(%TransformState{} = state, width, :auto) do
    scale = width / image_width(state)
    Image.resize(state.image, scale)
  end

  def do_scale(%TransformState{} = state, :auto, height) do
    scale = height / image_height(state)
    Image.resize(state.image, scale)
  end

  def do_scale(%TransformState{} = state, width, height) do
    width_scale = width / image_width(state)
    height_scale = height / image_height(state)
    Image.resize(state.image, width_scale, vertical_scale: height_scale)
  end

  def do_scale(_image, parameters) do
    {:error, {:unhandled_scale_parameters, parameters}}
  end

  defp to_pixels_or_auto(_length, :auto), do: :auto
  defp to_pixels_or_auto(length, size_unit), do: to_pixels(length, size_unit)
end
