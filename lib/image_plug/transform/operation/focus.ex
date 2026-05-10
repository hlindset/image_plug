defmodule ImagePlug.Transform.Operation.Focus do
  @moduledoc """
  Represents a product-neutral focus operation that records where later
  focus-aware transforms should center their work.

  ## Construct When

  Construct `Focus` when parser or planner code needs to set transform state
  for a later crop or cover operation. `Focus` is not a visible crop by itself;
  it records focus metadata on `ImagePlug.Transform.State`.

  The current Imgproxy parser does not emit `Focus`. Imgproxy focal-point gravity
  maps to `Crop` gravity fields instead. Future parsers may emit `Focus` when
  their dialect has a distinct focus operation whose semantics should affect a
  later crop.

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

  ## Examples

      focus = %ImagePlug.Transform.Operation.Focus{
        type: {:coordinate, {:percent, 35}, {:percent, 40}}
      }
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State, only: [set_focus: 2]

  import ImagePlug.Transform.Geometry,
    only: [
      anchor_to_pixels: 3,
      draw_debug_dot: 3,
      image_height: 1,
      image_width: 1,
      to_pixels!: 2
    ]

  alias ImagePlug.Transform.State
  alias ImagePlug.Transform.Validation

  @doc """
  The parsed operation used by `ImagePlug.Transform.Operation.Focus`.
  """
  defstruct [:type]

  @type t ::
          %__MODULE__{
            type:
              {:coordinate, ImagePlug.Transform.Types.length(),
               ImagePlug.Transform.Types.length()}
          }
          | %__MODULE__{type: State.focus_anchor()}

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :focus

  @impl ImagePlug.Transform
  def validate(%__MODULE__{type: {:coordinate, left, top}}) do
    with :ok <- Validation.non_negative_position("focus", :left, left) do
      Validation.non_negative_position("focus", :top, top)
    end
  end

  def validate(%__MODULE__{type: {:anchor, x, y}})
      when x in [:left, :center, :right] and y in [:top, :center, :bottom],
      do: :ok

  def validate(%__MODULE__{type: type}) do
    {:error, ArgumentError.exception("invalid focus type: #{inspect(type)}")}
  end

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{type: {:coordinate, left, top}}, %State{} = state) do
    left = to_pixels!(image_width(state), left)
    top = to_pixels!(image_height(state), top)

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
end
