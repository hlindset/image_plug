defmodule ImagePlug.Transform.Scale do
  @behaviour ImagePlug.Transform

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  defmodule ScaleParams do
    defmodule Dimensions do
      defstruct [:width, :height]

      @type t ::
              %__MODULE__{width: ImagePlug.imgp_length() | :auto, height: ImagePlug.imgp_length()}
              | %__MODULE__{
                  width: ImagePlug.imgp_length(),
                  height: ImagePlug.imgp_length() | :auto
                }
    end

    defmodule AspectRatio do
      defstruct [:aspect_ratio]

      @type t :: %__MODULE__{aspect_ratio: ImagePlug.imgp_ratio()}
    end

    @doc """
    The parsed parameters used by `ImagePlug.Transform.Scale`.
    """
    defstruct [:method]

    @type t :: %__MODULE__{method: Dimension.t() | AspectRatio.t()}
  end

  defp dimensions_for_scale_method(state, %ScaleParams.Dimensions{width: width, height: height}) do
    with {:ok, width} <- to_pixels(state, :width, width),
         {:ok, height} <- to_pixels(state, :height, height) do
      {:ok, %{width: width, height: height}}
    end
  end

  defp dimensions_for_scale_method(state, %ScaleParams.AspectRatio{
         aspect_ratio: {:ratio, ar_w, ar_h}
       }) do
    with {:ok, aspect_width} <- Transform.eval_number(ar_w),
         {:ok, aspect_height} <- Transform.eval_number(ar_h) do
      current_area = Image.width(state.image) * Image.height(state.image)
      target_height = :math.sqrt(current_area * aspect_height / aspect_width)
      target_width = target_height * aspect_width / aspect_height
      target_width = round(target_width)
      target_height = round(target_height)

      {:ok, %{width: target_width, height: target_height}}
    end
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %ScaleParams{method: scale_method}) do
    with {:ok, width_and_height} <- dimensions_for_scale_method(state, scale_method),
         {:ok, scaled_image} <- do_scale(state.image, width_and_height) do
      # reset focus to :center on scale
      %TransformState{state | image: scaled_image, focus: :center}
    end
  end

  def do_scale(image, %{width: width, height: :auto}) do
    scale = width / Image.width(image)
    Image.resize(image, scale)
  end

  def do_scale(image, %{width: :auto, height: height}) do
    scale = height / Image.height(image)
    Image.resize(image, scale)
  end

  def do_scale(image, %{width: width, height: height}) do
    width_scale = width / Image.width(image)
    height_scale = height / Image.height(image)
    Image.resize(image, width_scale, vertical_scale: height_scale)
  end

  def do_scale(_image, parameters) do
    {:error, {:unhandled_scale_parameters, parameters}}
  end

  def to_pixels(_state, _dimension, :auto), do: {:ok, :auto}
  def to_pixels(state, dimension, length), do: Transform.to_pixels(state, dimension, length)
end
