defmodule ImagePlug.Transform.Operation.AdaptiveResize do
  @moduledoc """
  Represents a product-neutral resize operation whose fit-or-fill behavior is
  selected at runtime from source image metadata.

  ## Construct When

  Construct this operation when parser or planner code needs auto resize
  semantics where the requested target dimensions are known but the final mode
  depends on the source image orientation. Use `ImagePlug.Transform.Operation.Resize`
  when the mode is already known at planning time.

  A parser may translate an Imgproxy auto-resize request into `AdaptiveResize`
  when the request should choose fill for matching source and target
  orientations and fit otherwise. The URL syntax is parser specific; the
  operation itself is product-neutral.

  ## Fields

  `rule` is required and must be an
  `ImagePlug.Transform.Geometry.DimensionRule` with `mode: :auto`.

  Rule `width` and `height` may be `:auto` or non-negative pixel dimensions.
  Runtime orientation comparison requires both dimensions to resolve to
  concrete target pixels; if either side is `:auto`, the operation falls back
  to fit behavior. Rule `min_width` and `min_height` may be `nil`, `:auto`, or
  non-negative pixel dimensions. `zoom_x`, `zoom_y`, and `dpr` must be positive
  numbers. `enlarge` must be a boolean.

  ## Execution Semantics

  `execute/2` compares the current source image orientation with the requested
  target orientation. If both orientations match, including square-to-square,
  the rule is changed to `mode: :fill`; otherwise it is changed to
  `mode: :fit`. If the requested target orientation cannot be computed, the
  operation chooses `:fit`.

  The operation then delegates to the resize operation with the resolved rule,
  so state updates, focus reset, no-op handling, and error recording follow
  `Resize` semantics.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :random}`. Adaptive resize must inspect the
  source image dimensions before it can choose fit or fill behavior, so it is
  not treated as a one-pass sequential decode candidate.

  ## Examples

      alias ImagePlug.Transform.Operation.AdaptiveResize
      alias ImagePlug.Transform.Geometry.DimensionRule

      adaptive_resize = %AdaptiveResize{
        rule: %DimensionRule{
          mode: :auto,
          width: {:pixels, 300},
          height: {:pixels, 200}
        }
      }
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.State
  alias ImagePlug.Transform.Validation

  defstruct [:rule]

  @type t :: %__MODULE__{rule: DimensionRule.t()}

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :adaptive_resize

  @impl ImagePlug.Transform
  def validate(%__MODULE__{rule: %DimensionRule{} = rule}) do
    Validation.dimension_rule("adaptive resize", :rule, rule, [:auto])
  end

  def validate(%__MODULE__{rule: rule}), do: Validation.invalid("adaptive resize", :rule, rule)

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{rule: %DimensionRule{} = rule}, %State{} = state) do
    updated_rule = %{rule | mode: adaptive_mode(state, rule)}

    Resize.execute(%Resize{rule: updated_rule}, state)
  end

  defp adaptive_mode(%State{} = state, %DimensionRule{} = rule) do
    case requested_dimensions(state, rule) do
      {:ok, %{width: width, height: height}} ->
        if same_orientation?(image_width(state), image_height(state), width, height) do
          :fill
        else
          :fit
        end

      :error ->
        :fit
    end
  end

  defp requested_dimensions(_state, %DimensionRule{width: :auto}), do: :error
  defp requested_dimensions(_state, %DimensionRule{height: :auto}), do: :error
  defp requested_dimensions(_state, %DimensionRule{width: nil}), do: :error
  defp requested_dimensions(_state, %DimensionRule{height: nil}), do: :error

  defp requested_dimensions(%State{} = state, %DimensionRule{} = rule) do
    {:ok,
     %{
       width: to_pixels!(image_width(state), rule.width),
       height: to_pixels!(image_height(state), rule.height)
     }}
  end

  defp same_orientation?(source_width, source_height, target_width, target_height) do
    orientation(source_width, source_height) == orientation(target_width, target_height)
  end

  defp orientation(width, height) when width > height, do: :landscape
  defp orientation(width, height) when width < height, do: :portrait
  defp orientation(_width, _height), do: :square
end
