defmodule ImagePlug.Transform.Resize do
  @moduledoc false

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.Geometry.DimensionResolver
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.State

  defstruct [:rule]

  @type t :: %__MODULE__{rule: DimensionRule.t()}

  @impl ImagePlug.Transform
  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    exception in [ArgumentError, KeyError] ->
      {:error, exception}
  end

  @impl ImagePlug.Transform
  def new!(%__MODULE__{} = operation), do: operation

  def new!(attrs) when is_list(attrs) or is_map(attrs) do
    attrs
    |> validate_attrs!()
    |> then(&struct!(__MODULE__, &1))
  end

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :resize

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{
        rule: %DimensionRule{
          mode: :fit,
          width: width,
          height: height,
          min_width: nil,
          min_height: nil
        }
      })
      when width != :auto or height != :auto,
      do: %{access: :sequential}

  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{rule: %DimensionRule{} = rule}, %State{} = state) do
    opts = [
      source_width: image_width(state),
      source_height: image_height(state)
    ]

    with {:ok, dimensions} <- DimensionResolver.resolve(rule, opts),
         {:ok, image} <-
           resize_image(state, dimensions.intermediate_width, dimensions.intermediate_height),
         {:ok, image} <-
           maybe_crop_fill_image(
             rule,
             image,
             dimensions.requested_width,
             dimensions.requested_height
           ) do
      state |> set_image(image) |> reset_focus()
    else
      {:error, _reason} = error -> add_error(state, {__MODULE__, error})
    end
  end

  defp resize_image(%State{} = state, width, height) do
    if width == image_width(state) and height == image_height(state) do
      {:ok, state.image}
    else
      width_scale = width / image_width(state)
      height_scale = height / image_height(state)

      Image.resize(state.image, width_scale, vertical_scale: height_scale)
    end
  end

  defp maybe_crop_fill_image(%DimensionRule{mode: mode}, image, requested_width, requested_height)
       when mode in [:fill, :fill_down] and requested_width != :auto and requested_height != :auto do
    crop_width = min(requested_width, Image.width(image))
    crop_height = min(requested_height, Image.height(image))

    if crop_width == Image.width(image) and crop_height == Image.height(image) do
      {:ok, image}
    else
      left = div(Image.width(image) - crop_width, 2)
      top = div(Image.height(image) - crop_height, 2)

      Image.crop(image, left, top, crop_width, crop_height)
    end
  end

  defp maybe_crop_fill_image(%DimensionRule{}, image, _requested_width, _requested_height),
    do: {:ok, image}

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)
    validate_keys!(attrs, [:rule])
    validate_rule!(Map.fetch!(attrs, :rule))
    attrs
  end

  defp validate_keys!(attrs, allowed_keys) do
    unknown_keys = Map.keys(attrs) -- allowed_keys

    if unknown_keys != [] do
      keys = unknown_keys |> Enum.sort_by(&inspect/1) |> Enum.map_join(", ", &inspect/1)
      raise ArgumentError, "unknown resize option(s): #{keys}"
    end
  end

  defp validate_rule!(%DimensionRule{} = rule) do
    case DimensionRule.validate(rule, modes: [:fit, :fill, :fill_down, :force]) do
      :ok ->
        :ok

      {:error, {field, value}} ->
        raise ArgumentError, "invalid resize rule #{field}: #{inspect(value)}"
    end
  end

  defp validate_rule!(rule), do: raise(ArgumentError, "invalid resize rule: #{inspect(rule)}")
end
