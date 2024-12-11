defmodule ImagePlug.Transform.Cover do
  @behaviour ImagePlug.Transform

  alias ImagePlug.Transform
  alias ImagePlug.TransformState

  defmodule CoverParams do
    @doc """
    The parsed parameters used by `ImagePlug.Transform.Cover`.
    """
    defstruct [:type, :ratio, :width, :height, :constraint]

    @type t ::
            %__MODULE__{
              type: :ratio,
              ratio: {ImagePlug.imgp_ratio(), ImagePlug.imgp_ratio()},
              constraint: :regular | :min | :max
            }
            | %__MODULE__{
                type: :dimensions,
                width: ImagePlug.imgp_length(),
                height: ImagePlug.imgp_length() | :auto,
                constraint: :regular | :min | :max
              }
            | %__MODULE__{
                type: :dimensions,
                width: ImagePlug.imgp_length() | :auto,
                height: ImagePlug.imgp_length(),
                constraint: :regular | :min | :max
              }
  end

  @impl ImagePlug.Transform
  def execute(%TransformState{} = state, %CoverParams{
        width: width,
        height: height,
        constraint: constraint
      }) do
    original_width = Image.width(state.image)
    original_height = Image.height(state.image)

    with {:ok, target_width} <-
           Transform.to_pixels(state, :width, width),
         {:ok, target_height} <-
           Transform.to_pixels(state, :height, height),
         {:ok, width_and_height} <-
           fit_cover(state, %{width: target_width, height: target_height}),
         {:ok, state} <-
           maybe_scale(state, Map.merge(width_and_height, %{constraint: constraint})),
         anchored_crop_params <-
           anchor_crop(state, %{
             width: target_width,
             height: target_height,
             original_width: original_width,
             original_height: original_height
           }),
         clamped_crop_params <- clamp(state, anchored_crop_params),
         {:ok, state} <- do_crop(state, clamped_crop_params) do
      state |> TransformState.reset_focus()
    end
  end

  def fit_cover(%TransformState{image: image}, target) do
    original_ar = Image.width(image) / Image.height(image)
    target_ar = target.width / target.height

    if original_ar > target_ar do
      scaled_width = round(target.height * original_ar)
      {:ok, %{width: scaled_width, height: target.height}}
    else
      scaled_height = round(target.width / original_ar)
      {:ok, %{width: target.width, height: scaled_height}}
    end
  end

  defp anchor_crop(
         %TransformState{} = state,
         %{
           width: width,
           height: height,
           original_width: original_width,
           original_height: original_height
         }
       ) do
    center_x =
      case state.focus do
        {:anchor, :left, _} -> width / 2
        {:anchor, :center, _} -> Image.width(state.image) / 2
        {:anchor, :right, _} -> Image.width(state.image) - width / 2
        {:coordinate, left, _top} -> width / original_width * left
      end

    center_y =
      case state.focus do
        {:anchor, _, :top} -> height / 2
        {:anchor, _, :center} -> Image.height(state.image) / 2
        {:anchor, _, :bottom} -> Image.height(state.image) - height / 2
        {:coordinate, _left, top} -> height / original_height * top
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

  def maybe_scale(
        %TransformState{image: image} = state,
        %{width: width, height: height, constraint: :min} = params
      ) do
    if width > Image.width(image) or height > Image.height(image),
      do: do_scale(state, params),
      else: {:ok, state}
  end

  def maybe_scale(
        %TransformState{image: image} = state,
        %{width: width, height: height, constraint: :max} = params
      ) do
    if width < Image.width(image) or height < Image.height(image),
      do: do_scale(state, params),
      else: {:ok, state}
  end

  def maybe_scale(image, params), do: do_scale(image, params)

  def do_scale(%TransformState{image: image} = state, %{width: width, height: height}) do
    width_scale = width / Image.width(image)
    height_scale = height / Image.height(image)

    case Image.resize(image, width_scale, vertical_scale: height_scale) do
      {:ok, resized_image} -> {:ok, %TransformState{state | image: resized_image}}
      {:error, _reason} = error -> error
    end
  end

  def do_crop(%TransformState{image: image} = state, %{
        width: width,
        height: height,
        top: top,
        left: left
      }) do
    case Image.crop(image, left, top, width, height) do
      {:ok, cropped_image} -> {:ok, %TransformState{state | image: cropped_image}}
      {:error, _reason} = error -> error
    end
  end
end
