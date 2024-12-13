defmodule ImagePlug.Transform.Contain do
  @behaviour ImagePlug.Transform

  import ImagePlug.TransformState
  import ImagePlug.Utils

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
    target_width = to_pixels(state, :x, width)
    target_height = to_pixels(state, :y, height)
    {resize_width, resize_height} = fit_inside(state, target_width, target_height)

    case maybe_scale(state, resize_width, resize_height, constraint) do
      {:ok, scaled_image} -> state |> set_image(scaled_image) |> reset_focus()
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end

  def fit_inside(%TransformState{} = state, target_width, target_height) do
    original_ar = image_width(state) / image_height(state)
    target_ar = target_width / target_height

    if original_ar > target_ar do
      {target_width, round(target_width / original_ar)}
    else
      {round(target_height * original_ar), target_height}
    end
  end

  def maybe_scale(%TransformState{} = state, width, height, :min) do
    if width > image_width(state) or height > image_height(state),
      do: do_scale(state, width, height),
      else: {:ok, state.image}
  end

  def maybe_scale(%TransformState{} = state, width, height, :max) do
    if width < image_width(state) or height < image_height(state),
      do: do_scale(state, width, height),
      else: {:ok, state.image}
  end

  def maybe_scale(%TransformState{} = state, width, height, _constraint),
    do: do_scale(state, width, height)

  def do_scale(%TransformState{} = state, width, height) do
    width_scale = width / image_width(state)
    height_scale = height / image_height(state)
    Image.resize(state.image, width_scale, vertical_scale: height_scale)
  end
end
