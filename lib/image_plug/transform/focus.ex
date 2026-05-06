defmodule ImagePlug.Transform.Focus do
  @moduledoc """
  Represents a product-neutral focus operation that records where later
  focus-aware transforms should center their work.

  ## Construct When

  Construct `Focus` when parser or planner code needs to set transform state
  for a later crop or cover operation. `Focus` is not a visible crop by itself;
  it records focus metadata on `ImagePlug.Transform.State`.

  The current Native parser does not emit `Focus`. Native focal-point gravity
  maps to `Crop` gravity fields instead. Future parsers may emit `Focus` when
  their dialect has a distinct focus operation whose semantics should affect a
  later crop.

  ## Construction API

  `new/1` accepts a keyword list, map, or existing `%Focus{}` and returns
  `{:ok, operation}` when all fields are valid. Invalid attributes, missing
  required fields, or unknown keys return `{:error, exception}`.

  `new!/1` accepts the same inputs and returns an operation, raising
  `ArgumentError` or `KeyError` for invalid attributes.

  ## Fields

  The required `type` field is one of:

  - `{:coordinate, left, top}` with non-negative coordinate lengths.
  - `{:anchor, x, y}` where `x` is `:left`, `:center`, or `:right`, and `y` is
    `:top`, `:center`, or `:bottom`.

  Coordinate lengths may be non-negative numbers, `{:pixels, value}`,
  `{:percent, value}`, `{:scale, value}`, or
  `{:scale, numerator, denominator}` with non-negative numeric positions and a
  positive denominator.

  ## Execution Semantics

  `execute/2` updates `ImagePlug.Transform.State.focus`. Coordinate focus is
  resolved against the current image dimensions, rounded to pixels, and clamped
  to the image bounds. Anchor focus is stored as the requested anchor tuple.

  In normal execution, `Focus` only changes focus state. When state debugging is
  enabled, execution also draws a debug dot at the resolved focus point and
  stores that debug image in state.

  Later operations such as `Cover` may use the focus state to choose a crop
  origin. Operations that reset focus after changing image geometry restore the
  default center focus.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :random}`. Focus can require current image
  dimensions to resolve coordinate focus and is intentionally not treated as a
  one-pass sequential decode candidate.

  ## Cache Material

  Material emits:

      [
        op: :focus,
        type: operation.type
      ]

  ## Examples

      {:ok, focus} =
        ImagePlug.Transform.Focus.new(
          type: {:coordinate, {:percent, 35}, {:percent, 40}}
        )

      bottom_right =
        ImagePlug.Transform.Focus.new!(
          type: {:anchor, :right, :bottom}
        )
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.State

  @doc """
  The parsed operation used by `ImagePlug.Transform.Focus`.
  """
  defstruct [:type]

  @type t ::
          %__MODULE__{type: {:coordinate, ImagePlug.imgp_length(), ImagePlug.imgp_length()}}
          | %__MODULE__{type: State.focus_anchor()}

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
    |> Map.from_struct()
    |> validate_attrs!()

    operation
  end

  def new!(attrs) when is_list(attrs) or is_map(attrs) do
    attrs
    |> validate_attrs!()
    |> then(&struct!(__MODULE__, &1))
  end

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :focus

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{type: {:coordinate, left, top}}, %State{} = state) do
    left = to_pixels(image_width(state), left)
    top = to_pixels(image_height(state), top)

    focus =
      {:coordinate, max(min(image_width(state), left), 0), max(min(image_height(state), top), 0)}

    state
    |> set_focus(focus)
    |> maybe_draw_debug_dot()
  end

  @impl ImagePlug.Transform
  def execute(%__MODULE__{type: {:anchor, x, y}}, %State{} = state) do
    state
    |> set_focus({:anchor, x, y})
    |> maybe_draw_debug_dot()
  end

  defp maybe_draw_debug_dot(%State{debug: true, focus: focus} = state) do
    {left, top} = anchor_to_pixels(focus, image_width(state), image_height(state))
    draw_debug_dot(state, left, top)
  end

  defp maybe_draw_debug_dot(%State{} = state), do: state

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)
    validate_keys!(attrs, [:type])

    case Map.fetch!(attrs, :type) do
      {:coordinate, left, top} ->
        validate_position!(:left, left)
        validate_position!(:top, top)
        attrs

      {:anchor, x, y} when x in [:left, :center, :right] and y in [:top, :center, :bottom] ->
        attrs

      type ->
        raise ArgumentError, "invalid focus type: #{inspect(type)}"
    end
  end

  defp validate_keys!(attrs, allowed_keys) do
    unknown_keys = Map.keys(attrs) -- allowed_keys

    if unknown_keys != [] do
      keys = unknown_keys |> Enum.sort_by(&inspect/1) |> Enum.map_join(", ", &inspect/1)
      raise ArgumentError, "unknown focus option(s): #{keys}"
    end
  end

  defp validate_position!(_field, value) when is_number(value) and value >= 0, do: :ok
  defp validate_position!(_field, {:pixels, value}) when is_number(value) and value >= 0, do: :ok
  defp validate_position!(_field, {:percent, value}) when is_number(value) and value >= 0, do: :ok
  defp validate_position!(_field, {:scale, value}) when is_number(value) and value >= 0, do: :ok

  defp validate_position!(_field, {:scale, numerator, denominator})
       when is_number(numerator) and is_number(denominator) and numerator >= 0 and denominator > 0,
       do: :ok

  defp validate_position!(field, value),
    do: raise(ArgumentError, "invalid focus #{field}: #{inspect(value)}")
end
