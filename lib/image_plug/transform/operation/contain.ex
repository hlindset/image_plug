defmodule ImagePlug.Transform.Operation.Contain do
  @moduledoc """
  Represents an executable contain operation that scales image content to
  fit inside a requested box or aspect ratio.

  ## Construct When

  Transform Plan execution may convert semantic Plan operations to this
  executable operation. Parser modules should construct
  `ImagePlug.Plan.Operation.*` through Plan constructors.

  `Contain` is retained as an exported standalone executable operation, not an
  implementation detail of `Resize`.

  ## Fields

  For `type: :dimensions`, these fields are required:

  - `width`: positive length or `:auto`.
  - `height`: positive length or `:auto`.
  - `constraint`: `:regular`, `:min`, or `:max`.
  - `letterbox`: boolean.

  At least one dimension must be a positive length; `width: :auto` with
  `height: :auto` is rejected. Positive lengths may be numbers,
  `{:pixels, value}`, `{:percent, value}`, `{:scale, value}`, or
  `{:scale, numerator, denominator}` with positive numeric values and a
  positive denominator.

  For `type: :ratio`, these fields are required:

  - `ratio`: `{width, height}` with positive numeric values.
  - `letterbox`: boolean.

  ## Execution Semantics

  `execute/2` resolves the target size against the current
  `ImagePlug.Transform.State` image dimensions, computes the largest
  aspect-preserving size that fits inside that target, and resizes the current
  image according to `constraint`.

  `constraint: :regular` always scales to the fitted size. `:min` scales only
  when the fitted size would enlarge at least one axis. `:max` scales only when
  the fitted size would shrink at least one axis.

  When `letterbox` is `true`, the fitted image is embedded in the requested
  target box with a white background. Ratio contain requests compute a target
  box with the requested ratio around the current image; without letterboxing,
  that ratio form may leave the visible image unchanged.

  On success, the resulting image is stored in state and focus is reset. Image
  processing failures are added to state as `{ImagePlug.Transform.Operation.Contain,
  error}`.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :sequential}` only for `type: :dimensions`
  with `constraint: :regular` and `letterbox: false`.

  Ratio contain requests, constrained resize requests, and letterboxed requests
  return `%{access: :random}` because they require source geometry inspection,
  conditional behavior, or canvas embedding.

  ## Examples

      contain = %ImagePlug.Transform.Operation.Contain{
        type: :dimensions,
        width: {:pixels, 800},
        height: {:pixels, 600},
        constraint: :regular,
        letterbox: false
      }
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State, only: [add_error: 2, reset_focus: 1, set_image: 2]

  import ImagePlug.Transform.Geometry,
    only: [image_height: 1, image_width: 1, resolve_auto_size: 3]

  alias ImagePlug.Transform.State
  alias ImagePlug.Transform.Validation

  defstruct [:type, :ratio, :width, :height, :constraint, :letterbox]

  @type t ::
          %__MODULE__{
            type: :ratio,
            ratio: ImagePlug.Transform.Types.ratio(),
            letterbox: boolean()
          }
          | %__MODULE__{
              type: :dimensions,
              width: ImagePlug.Transform.Types.length(),
              height: ImagePlug.Transform.Types.length() | :auto,
              constraint: :regular | :min | :max,
              letterbox: boolean()
            }
          | %__MODULE__{
              type: :dimensions,
              width: ImagePlug.Transform.Types.length() | :auto,
              height: ImagePlug.Transform.Types.length(),
              constraint: :regular | :min | :max,
              letterbox: boolean()
            }

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :contain

  @impl ImagePlug.Transform
  def validate(%__MODULE__{
        type: :dimensions,
        ratio: nil,
        width: width,
        height: height,
        constraint: constraint,
        letterbox: letterbox
      }) do
    with :ok <- Validation.positive_dimension_pair("contain", width, height),
         :ok <- Validation.one_of("contain", :constraint, constraint, [:regular, :min, :max]) do
      Validation.boolean("contain", :letterbox, letterbox)
    end
  end

  def validate(%__MODULE__{
        type: :ratio,
        ratio: ratio,
        width: nil,
        height: nil,
        constraint: nil,
        letterbox: letterbox
      }) do
    with :ok <- Validation.ratio("contain", :ratio, ratio) do
      Validation.boolean("contain", :letterbox, letterbox)
    end
  end

  def validate(%__MODULE__{type: type}) do
    {:error, ArgumentError.exception("invalid contain type: #{inspect(type)}")}
  end

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{
        type: :dimensions,
        constraint: :regular,
        letterbox: false
      }),
      do: %{access: :sequential}

  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(
        %__MODULE__{
          type: :ratio,
          ratio: {ratio_width, ratio_height},
          # Note: Not letterboxing doesn't make sense with this implementation,
          #       as the transformation would just return the same image
          letterbox: letterbox
        } = _params,
        %State{} = state
      ) do
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

    execute(
      %__MODULE__{
        type: :dimensions,
        width: target_width,
        height: target_height,
        constraint: :regular,
        letterbox: letterbox
      },
      state
    )
  end

  @impl ImagePlug.Transform
  def execute(
        %__MODULE__{
          type: :dimensions,
          width: width,
          height: height,
          constraint: constraint,
          letterbox: letterbox
        },
        %State{} = state
      ) do
    {target_width, target_height} = resolve_auto_size(state, width, height)
    {resize_width, resize_height} = fit_inside(state, target_width, target_height)

    with {:ok, state} <- maybe_scale(state, resize_width, resize_height, constraint),
         {:ok, state} <- maybe_add_letterbox(state, letterbox, target_width, target_height) do
      reset_focus(state)
    else
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end

  defp fit_inside(%State{} = state, target_width, target_height) do
    original_ar = image_width(state) / image_height(state)
    target_ar = target_width / target_height

    if original_ar > target_ar do
      {target_width, round(target_width / original_ar)}
    else
      {round(target_height * original_ar), target_height}
    end
  end

  defp maybe_scale(%State{} = state, width, height, :min) do
    if width > image_width(state) or height > image_height(state),
      do: do_scale(state, width, height),
      else: {:ok, state}
  end

  defp maybe_scale(%State{} = state, width, height, :max) do
    if width < image_width(state) or height < image_height(state),
      do: do_scale(state, width, height),
      else: {:ok, state}
  end

  defp maybe_scale(%State{} = state, width, height, _constraint),
    do: do_scale(state, width, height)

  defp do_scale(%State{} = state, width, height) do
    width_scale = width / image_width(state)
    height_scale = height / image_height(state)

    case Image.resize(state.image, width_scale, vertical_scale: height_scale) do
      {:ok, resized_image} -> {:ok, set_image(state, resized_image)}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_add_letterbox(state, letterbox?, width, height)
  defp maybe_add_letterbox(%State{} = state, false, _width, _height), do: {:ok, state}

  defp maybe_add_letterbox(%State{} = state, true, width, height) do
    case Image.embed(state.image, width, height, background_color: :white) do
      {:ok, letterboxed_image} -> {:ok, set_image(state, letterboxed_image)}
      {:error, _reason} = error -> error
    end
  end
end
