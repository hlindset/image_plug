defmodule ImagePlug.Transform.Operation.Resize do
  @moduledoc """
  Represents an executable resize operation whose dimension mode is known
  before execution.

  ## Construct When

  Transform Plan execution may convert semantic Plan operations to this
  executable operation after a cache miss. Parser modules should construct
  `ImagePlug.Plan.Operation.*` through Plan constructors.

  Use `Resize` for resolved `:fit`, `:fill`, `:fill_down`, and `:force` work.

  ## Fields

  `rule` is required and must be an
  `ImagePlug.Transform.Geometry.DimensionRule` with one of these modes:

  - `:fit` scales the image proportionally so it fits inside the requested box.
  - `:fill` scales the image proportionally to cover the requested box; any
    visible crop is represented by a separate crop operation.
  - `:fill_down` behaves like fill but does not enlarge raster sources beyond
    their source dimensions.
  - `:force` resizes each requested side independently and may change aspect
    ratio.

  Rule `width` and `height` may be `:auto` or non-negative pixel dimensions.
  `{:pixels, 0}` is normalized by dimension resolution as `:auto`. For
  `:force`, an auto side preserves the corresponding source dimension, so a
  zero-width force resize with a requested height keeps the source width and
  forces the height. For proportional modes, an auto side is resolved from the
  source aspect ratio.

  Rule `min_width` and `min_height` may be `nil`, `:auto`, or non-negative
  pixel dimensions. `zoom_x`, `zoom_y`, and `dpr` must be positive numbers.
  `enlarge` must be a boolean.

  ## Execution Semantics

  `execute/2` resolves the rule against the current
  `ImagePlug.Transform.State` image dimensions, resizes the image to the
  resolved intermediate width and height, stores the resized image in state,
  and resets focus metadata. If the resolved intermediate dimensions equal the
  current image dimensions, the existing image is kept. Dimension resolution or
  image resize failures are added to state as
  `{ImagePlug.Transform.Operation.Resize, error}`.

  `Resize` does not perform result cropping. Transform Plan execution for
  cover-style output should include a separate crop operation after a fill-like
  resize when that matches the requested semantics.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :sequential}` only for `:fit` and `:force`
  rules with no minimum dimensions and at least one requested positive
  dimension. Requested dimensions exclude `:auto` and non-positive pixel
  dimensions.

  All `:fill` and `:fill_down` requests, rules with minimum dimensions, and
  rules without requested geometry return `%{access: :random}` because their
  final geometry depends on source metadata or later crop behavior.

  ## Examples

      alias ImagePlug.Transform.Geometry.DimensionRule
      alias ImagePlug.Transform.Operation.Resize

      resize = %Resize{
        rule: %DimensionRule{
          mode: :fit,
          width: {:pixels, 300},
          height: :auto,
          enlarge: false
        }
      }
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.Geometry.DimensionResolver
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.State
  alias ImagePlug.Transform.Validation

  defstruct [:rule]

  @type t :: %__MODULE__{rule: DimensionRule.t()}

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :resize

  @impl ImagePlug.Transform
  def validate(%__MODULE__{rule: %DimensionRule{} = rule}) do
    Validation.dimension_rule("resize", :rule, rule, [:fit, :fill, :fill_down, :force])
  end

  def validate(%__MODULE__{rule: rule}), do: Validation.invalid("resize", :rule, rule)

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{
        rule: %DimensionRule{
          mode: mode,
          width: width,
          height: height,
          min_width: nil,
          min_height: nil
        }
      })
      when mode in [:fit, :force] do
    if requested_dimension?(width) or requested_dimension?(height) do
      %{access: :sequential}
    else
      %{access: :random}
    end
  end

  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{rule: %DimensionRule{} = rule}, %State{} = state) do
    opts = [
      source_width: image_width(state),
      source_height: image_height(state)
    ]

    with {:ok, dimensions} <- DimensionResolver.resolve(rule, opts),
         {:ok, image} <-
           resize_image(state, dimensions.intermediate_width, dimensions.intermediate_height) do
      state |> set_image(image) |> reset_focus()
    else
      {:error, _reason} = error -> add_error(state, {__MODULE__, error})
    end
  end

  defp resize_image(%State{} = state, width, height) do
    source_width = image_width(state)
    source_height = image_height(state)

    cond do
      source_width <= 0 or source_height <= 0 ->
        {:error, {:invalid_source_dimensions, source_width, source_height}}

      width == source_width and height == source_height ->
        {:ok, state.image}

      true ->
        width_scale = width / source_width
        height_scale = height / source_height

        Image.resize(state.image, width_scale, vertical_scale: height_scale)
    end
  end

  defp requested_dimension?(:auto), do: false
  defp requested_dimension?({:pixels, value}) when is_number(value) and value <= 0, do: false
  defp requested_dimension?(_dimension), do: true
end
