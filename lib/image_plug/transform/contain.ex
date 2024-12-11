defmodule ImagePlug.Transform.Contain do
  @behaviour ImagePlug.Transform

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  defmodule ContainParams do
    defstruct [:width, :height, :constraint]

    @type t ::
            %__MODULE__{
              width: ImagePlug.imgp_length(),
              height: ImagePlug.imgp_length(),
              constraint: :regular | :min | :max
            }
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %ContainParams{
        width: width,
        height: height,
        constraint: constraint
      }) do
    with {:ok, target_width} <- Transform.to_pixels(state, :width, width),
         {:ok, target_height} <- Transform.to_pixels(state, :height, height),
         {:ok, width_and_height} <-
           fit_inside(state, %{width: target_width, height: target_height}),
         {:ok, scaled_image} <-
           maybe_scale(state.image, Map.merge(width_and_height, %{constraint: constraint})) do
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

  def maybe_scale(image, %{width: width, height: height, constraint: :min} = params) do
    if width > Image.width(image) or height > Image.height(image),
      do: do_scale(image, params),
      else: {:ok, image}
  end

  def maybe_scale(image, %{width: width, height: height, constraint: :max} = params) do
    if width < Image.width(image) or height < Image.height(image),
      do: do_scale(image, params),
      else: {:ok, image}
  end

  def maybe_scale(image, params), do: do_scale(image, params)

  def do_scale(image, %{width: width, height: height}) do
    width_scale = width / Image.width(image)
    height_scale = height / Image.height(image)
    Image.resize(image, width_scale, vertical_scale: height_scale)
  end
end
