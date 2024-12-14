defmodule ImagePlug.Transform.Contain do
  @behaviour ImagePlug.Transform

  import ImagePlug.TransformState
  import ImagePlug.Utils

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  defmodule ContainParams do
    defstruct [:type, :ratio, :width, :height, :constraint, :letterbox]

    @type t ::
            %__MODULE__{
              type: :ratio,
              ratio: ImagePlug.imgp_ratio(),
              letterbox: boolean()
            }
            | %__MODULE__{
                type: :dimensions,
                width: ImagePlug.imgp_length(),
                height: ImagePlug.imgp_length() | :auto,
                constraint: :regular | :min | :max,
                letterbox: boolean()
              }
            | %__MODULE__{
                type: :dimensions,
                width: ImagePlug.imgp_length() | :auto,
                height: ImagePlug.imgp_length(),
                constraint: :regular | :min | :max,
                letterbox: boolean()
              }
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %ContainParams{
        type: :ratio,
        ratio: {ratio_width, ratio_height},
        # Note: Not letterboxing doesn't make sense with this implementation,
        #       as the transformation would just return the same image
        letterbox: letterbox
      }) do
    # compute target width and height based on the ratio
    image_width = image_width(state)
    image_height = image_height(state)

    target_ratio = ratio_width / ratio_height
    original_ratio = image_width / image_height

    {target_width, target_height} =
      if original_ratio > target_ratio do
        # wider image: scale height to match ratio
        {image_width, round(image_width / target_ratio)}
      else
        # taller image: scale width to match ratio
        {round(image_height * target_ratio), image_height}
      end

    execute(state, %ContainParams{
      type: :dimensions,
      width: target_width,
      height: target_height,
      constraint: :none,
      letterbox: letterbox
    })
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %ContainParams{
        type: :dimensions,
        width: width,
        height: height,
        constraint: constraint,
        letterbox: letterbox
      }) do
    {target_width, target_height} = resolve_auto_size(state, width, height)
    {resize_width, resize_height} = fit_inside(state, target_width, target_height)

    with {:ok, state} <- maybe_scale(state, resize_width, resize_height, constraint),
         {:ok, state} <- maybe_add_letterbox(state, letterbox, target_width, target_height) do
      state |> reset_focus()
    else
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
      else: {:ok, state}
  end

  def maybe_scale(%TransformState{} = state, width, height, :max) do
    if width < image_width(state) or height < image_height(state),
      do: do_scale(state, width, height),
      else: {:ok, state}
  end

  def maybe_scale(%TransformState{} = state, width, height, _constraint),
    do: do_scale(state, width, height)

  def do_scale(%TransformState{} = state, width, height) do
    width_scale = width / image_width(state)
    height_scale = height / image_height(state)

    case Image.resize(state.image, width_scale, vertical_scale: height_scale) do
      {:ok, resized_image} -> {:ok, set_image(state, resized_image)}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_add_letterbox(state, letterbox?, width, height)
  defp maybe_add_letterbox(%TransformState{} = state, false, width, height), do: {:ok, state}

  defp maybe_add_letterbox(%TransformState{} = state, true, width, height) do
    case Image.embed(state.image, width, height, background_color: :average) do
      {:ok, letterboxed_image} -> {:ok, set_image(state, letterboxed_image)}
      {:error, _reason} = error -> error
    end
  end
end
