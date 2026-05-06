defmodule ImagePlug.Transform.Contain do
  @moduledoc """
  Represents a product-neutral contain operation that scales image content to
  fit inside a requested box or aspect ratio.

  ## Construct When

  Construct `Contain` when parser or planner code needs contain semantics:
  preserve aspect ratio, fit the current image inside a target geometry, and
  optionally letterbox the result. `Contain` is an exported standalone
  operation, not an implementation detail of `Resize`.

  Prefer `Resize` when the request is a planned fit, fill, fill-down, or force
  resize expressed through a dimension rule. A future dialect parser may choose
  `Contain` directly when the dialect exposes contain behavior, especially when
  its syntax couples fit-inside resizing with letterboxing.

  ## Construction API

  `new/1` accepts a keyword list, map, or existing `%Contain{}` and returns
  `{:ok, operation}` when all fields are valid. Invalid attributes, missing
  required fields, or unknown keys return `{:error, exception}`.

  `new!/1` accepts the same inputs and returns an operation, raising
  `ArgumentError` or `KeyError` for invalid attributes.

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
  processing failures are added to state as `{ImagePlug.Transform.Contain,
  error}`.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :sequential}` only for `type: :dimensions`
  with `constraint: :regular` and `letterbox: false`.

  Ratio contain requests, constrained resize requests, and letterboxed requests
  return `%{access: :random}` because they require source geometry inspection,
  conditional behavior, or canvas embedding.

  ## Cache Material

  For `type: :ratio`, material emits:

      [
        op: :contain,
        type: operation.type,
        ratio: operation.ratio,
        letterbox: operation.letterbox
      ]

  For `type: :dimensions`, material emits:

      [
        op: :contain,
        type: operation.type,
        width: operation.width,
        height: operation.height,
        constraint: operation.constraint,
        letterbox: operation.letterbox
      ]

  ## Examples

      {:ok, contain} =
        ImagePlug.Transform.Contain.new(
          type: :dimensions,
          width: {:pixels, 800},
          height: {:pixels, 600},
          constraint: :regular,
          letterbox: false
        )

      letterboxed =
        ImagePlug.Transform.Contain.new!(
          type: :ratio,
          ratio: {16, 9},
          letterbox: true
        )
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.State

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

  @impl ImagePlug.Transform
  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    exception in [ArgumentError, KeyError] ->
      {:error, exception}
  end

  @impl ImagePlug.Transform
  def new!(%__MODULE__{} = operation) do
    operation
    |> attrs_from_operation()
    |> validate_attrs!()

    operation
  end

  def new!(attrs) when is_list(attrs) or is_map(attrs) do
    attrs
    |> validate_attrs!()
    |> then(&struct!(__MODULE__, &1))
  end

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :contain

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
        constraint: :none,
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
      state |> reset_focus()
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

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)

    case Map.fetch!(attrs, :type) do
      :dimensions ->
        validate_keys!(attrs, [:type, :width, :height, :constraint, :letterbox])
        width = Map.fetch!(attrs, :width)
        height = Map.fetch!(attrs, :height)
        constraint = Map.fetch!(attrs, :constraint)
        validate_dimension_pair!(width, height)
        validate_constraint!(constraint, [:regular, :min, :max])
        validate_letterbox!(Map.fetch!(attrs, :letterbox))
        attrs

      :ratio ->
        validate_keys!(attrs, [:type, :ratio, :letterbox])
        validate_ratio!(Map.fetch!(attrs, :ratio))
        validate_letterbox!(Map.fetch!(attrs, :letterbox))
        attrs

      type ->
        raise ArgumentError, "invalid contain type: #{inspect(type)}"
    end
  end

  defp attrs_from_operation(%__MODULE__{type: :dimensions} = operation) do
    %{
      type: operation.type,
      width: operation.width,
      height: operation.height,
      constraint: operation.constraint,
      letterbox: operation.letterbox
    }
  end

  defp attrs_from_operation(%__MODULE__{type: :ratio} = operation) do
    %{type: operation.type, ratio: operation.ratio, letterbox: operation.letterbox}
  end

  defp attrs_from_operation(%__MODULE__{} = operation), do: %{type: operation.type}

  defp validate_keys!(attrs, allowed_keys) do
    unknown_keys = Map.keys(attrs) -- allowed_keys

    if unknown_keys != [] do
      keys = unknown_keys |> Enum.sort_by(&inspect/1) |> Enum.map_join(", ", &inspect/1)
      raise ArgumentError, "unknown contain option(s): #{keys}"
    end
  end

  defp validate_dimension_pair!(width, height) do
    validate_dimension_or_auto!(:width, width)
    validate_dimension_or_auto!(:height, height)

    if width == :auto and height == :auto do
      raise ArgumentError, "invalid contain dimensions: width and height cannot both be :auto"
    end
  end

  defp validate_dimension_or_auto!(_field, :auto), do: :ok

  defp validate_dimension_or_auto!(field, value), do: validate_dimension!(field, value)

  defp validate_dimension!(_field, value) when is_number(value) and value > 0, do: :ok
  defp validate_dimension!(_field, {:pixels, value}) when is_number(value) and value > 0, do: :ok
  defp validate_dimension!(_field, {:percent, value}) when is_number(value) and value > 0, do: :ok
  defp validate_dimension!(_field, {:scale, value}) when is_number(value) and value > 0, do: :ok

  defp validate_dimension!(_field, {:scale, numerator, denominator})
       when is_number(numerator) and is_number(denominator) and numerator > 0 and denominator > 0,
       do: :ok

  defp validate_dimension!(field, value),
    do: raise(ArgumentError, "invalid contain #{field}: #{inspect(value)}")

  defp validate_ratio!({width, height})
       when is_number(width) and is_number(height) and width > 0 and height > 0,
       do: :ok

  defp validate_ratio!(ratio),
    do: raise(ArgumentError, "invalid contain ratio: #{inspect(ratio)}")

  defp validate_constraint!(constraint, allowed) do
    if constraint in allowed do
      :ok
    else
      raise ArgumentError, "invalid contain constraint: #{inspect(constraint)}"
    end
  end

  defp validate_letterbox!(letterbox) when is_boolean(letterbox), do: :ok

  defp validate_letterbox!(letterbox),
    do: raise(ArgumentError, "invalid contain letterbox: #{inspect(letterbox)}")
end
