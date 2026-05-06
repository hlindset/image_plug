defmodule ImagePlug.Transform.Resize do
  @moduledoc """
  Represents a product-neutral resize operation whose dimension mode is known
  before execution.

  ## Construct When

  Construct this operation when parser or planner code has already selected a
  concrete resize mode and can express the requested geometry as an
  `ImagePlug.Transform.Geometry.DimensionRule`. Use `Resize` for fixed
  `:fit`, `:fill`, `:fill_down`, and `:force` requests. Use
  `ImagePlug.Transform.AdaptiveResize` when the mode must be chosen at runtime
  from source image metadata.

  A parser may translate a Native URL such as
  `/_/rt:force/w:0/h:200/plain/image.jpg` into a `Resize` with `mode: :force`,
  `width: :auto`, and `height: {:pixels, 200}`. The URL syntax is parser
  specific; the operation itself is product-neutral.

  ## Construction API

  `new/1` accepts a keyword list and returns
  `{:ok, operation}` when the attrs are valid or `{:error, reason}` when
  validation fails. `new!/1` accepts the same input and returns the operation
  or raises for invalid attrs.

  The only accepted attr is `:rule`.

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
  current image dimensions, the existing image is kept. Resolver or image
  resize failures are added to state as `{ImagePlug.Transform.Resize, error}`.

  `Resize` does not perform result cropping. Planners that need cover-style
  output should emit a separate crop operation after a fill-like resize when
  that matches the requested semantics.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :sequential}` only for `:fit` and `:force`
  rules with no minimum dimensions and at least one requested positive
  dimension. Requested dimensions exclude `:auto` and non-positive pixel
  dimensions.

  All `:fill` and `:fill_down` requests, rules with minimum dimensions, and
  rules without requested geometry return `%{access: :random}` because their
  final geometry depends on source metadata or later crop behavior.

  ## Cache Material

  The `ImagePlug.Transform.Material` implementation emits this keyword shape:

      [
        op: :resize,
        rule: [
          mode: rule.mode,
          width: rule.width,
          height: rule.height,
          min_width: rule.min_width,
          min_height: rule.min_height,
          zoom_x: rule.zoom_x,
          zoom_y: rule.zoom_y,
          dpr: rule.dpr,
          effective_dpr: :runtime_resolved,
          enlarge: rule.enlarge
        ]
      ]

  `effective_dpr` is materialized as `:runtime_resolved` because the effective
  device-pixel ratio may depend on runtime source metadata.

  ## Examples

      alias ImagePlug.Transform.Geometry.DimensionRule
      alias ImagePlug.Transform.Resize

      {:ok, resize} =
        Resize.new(
          rule: %DimensionRule{
            mode: :fit,
            width: {:pixels, 300},
            height: :auto,
            enlarge: false
          }
        )

      force =
        Resize.new!(
          rule: %DimensionRule{
            mode: :force,
            width: :auto,
            height: {:pixels, 200}
          }
        )
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

  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    exception in [ArgumentError, KeyError] ->
      {:error, exception}
  end

  def new!(attrs) when is_list(attrs) do
    attrs
    |> validate_attrs!()
    |> then(&struct!(__MODULE__, &1))
  end

  def new!(attrs), do: Validation.invalid_options!("resize", attrs)

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :resize

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
    if width == image_width(state) and height == image_height(state) do
      {:ok, state.image}
    else
      width_scale = width / image_width(state)
      height_scale = height / image_height(state)

      Image.resize(state.image, width_scale, vertical_scale: height_scale)
    end
  end

  defp requested_dimension?(:auto), do: false
  defp requested_dimension?({:pixels, value}) when is_number(value) and value <= 0, do: false
  defp requested_dimension?(_dimension), do: true

  defp validate_attrs!(attrs) do
    attrs = Validation.attrs!(attrs, [:rule], "resize")
    validate_rule!(Map.fetch!(attrs, :rule))
    attrs
  end

  defp validate_rule!(%DimensionRule{} = rule) do
    Validation.dimension_rule!("resize", :rule, rule, [:fit, :fill, :fill_down, :force])
  end

  defp validate_rule!(rule), do: Validation.invalid!("resize", :rule, rule)
end
