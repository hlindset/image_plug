defmodule ImagePlug.Transform.Scale do
  @behaviour ImagePlug.Transform

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  defmodule ScaleParams do
    @doc """
    The parsed parameters used by `ImagePlug.Transform.Scale`.
    """
    defstruct [:width, :height]

    @type t ::
            %__MODULE__{width: ImagePlug.imgp_length() | :auto, height: ImagePlug.imgp_length()}
            | %__MODULE__{width: ImagePlug.imgp_length(), height: ImagePlug.imgp_length() | :auto}
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %ScaleParams{} = parameters) do
    with {:ok, width} <- to_coord(state, :width, parameters.width),
         {:ok, height} <- to_coord(state, :height, parameters.height),
         {:ok, scaled_image} <- do_scale(state.image, %{width: width, height: height}) do
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

  def to_coord(_state, _dimension, :auto), do: {:ok, :auto}
  def to_coord(state, dimension, length), do: Transform.to_coord(state, dimension, length)
end
