defmodule ImagePlug.Transform.Contain do
  @behaviour ImagePlug.Transform

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  defmodule ContainParams do
    @doc """
    The parsed parameters used by `ImagePlug.Transform.Contain`.
    """
    defstruct [:width, :height]

    @type t :: %__MODULE__{width: ImagePlug.imgp_length(), height: ImagePlug.imgp_length()}
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %ContainParams{width: width, height: height}) do
    with {:ok, target_width} <- Transform.to_pixels(state, :width, width),
         {:ok, target_height} <- Transform.to_pixels(state, :height, height),
         {:ok, width_and_height} <-
           fit_inside(state, %{width: target_width, height: target_height}),
         {:ok, scaled_image} <- do_scale(state.image, width_and_height) do
      %TransformState{state | image: scaled_image} |> TransformState.reset_focus()
    end
  end

  def fit_inside(%TransformState{image: image}, target) do
    original_ar = Image.width(image) / Image.height(image)
    target_ar = target.width / target.height

    if original_ar > target_ar do
      {:ok, %{width: target.width, height: round(target.width / original_ar)}}
    else
      {:ok, %{width: round(target.height * original_ar), height: target.height}}
    end
  end

  def do_scale(image, %{width: width, height: height}) do
    width_scale = width / Image.width(image)
    height_scale = height / Image.height(image)
    Image.resize(image, width_scale, vertical_scale: height_scale)
  end
end
