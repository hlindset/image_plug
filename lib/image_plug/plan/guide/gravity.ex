defmodule ImagePlug.Plan.Guide.Gravity do
  @moduledoc """
  Canonical semantic guide for gravity and focal placement.
  """

  alias ImagePlug.Plan.Geometry.Dimension

  @x_anchors [:left, :center, :right]
  @y_anchors [:top, :center, :bottom]
  @spaces [:source, :current, :post_orient]
  @enforce_keys [:type, :space]
  defstruct [:type, :x, :y, :space]

  @type t :: %__MODULE__{
          type: :anchor | :focal_point,
          x: :left | :center | :right | Dimension.t(),
          y: :top | :center | :bottom | Dimension.t(),
          space: :source | :current | :post_orient
        }

  @type error ::
          {:invalid_gravity, {:anchor, term(), term()}}
          | {:invalid_gravity, {:focal_point, term(), term(), term(), term(), term()}}

  @spec anchor(term(), term()) :: {:ok, t()} | {:error, error()}
  def anchor(x, y) when x in @x_anchors and y in @y_anchors do
    {:ok, %__MODULE__{type: :anchor, x: x, y: y, space: :current}}
  end

  def anchor(x, y), do: {:error, {:invalid_gravity, {:anchor, x, y}}}

  @spec focal_point(term(), term(), term(), term(), term()) :: {:ok, t()} | {:error, error()}
  def focal_point(x_numerator, x_denominator, y_numerator, y_denominator, space \\ :current)

  def focal_point(x_numerator, x_denominator, y_numerator, y_denominator, space)
      when space in @spaces do
    with {:ok, x} <- focal_ratio(x_numerator, x_denominator),
         {:ok, y} <- focal_ratio(y_numerator, y_denominator) do
      {:ok, %__MODULE__{type: :focal_point, x: x, y: y, space: space}}
    else
      {:error, _reason} ->
        {:error,
         {:invalid_gravity,
          {:focal_point, x_numerator, x_denominator, y_numerator, y_denominator, space}}}
    end
  end

  def focal_point(x_numerator, x_denominator, y_numerator, y_denominator, space),
    do:
      {:error,
       {:invalid_gravity,
        {:focal_point, x_numerator, x_denominator, y_numerator, y_denominator, space}}}

  defp focal_ratio(0, denominator) when is_integer(denominator) and denominator > 0 do
    {:ok, %Dimension{unit: :ratio, numerator: 0, denominator: 1}}
  end

  defp focal_ratio(numerator, denominator), do: Dimension.ratio(numerator, denominator)
end
