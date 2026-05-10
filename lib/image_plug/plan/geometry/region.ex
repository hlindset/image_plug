defmodule ImagePlug.Plan.Geometry.Region do
  @moduledoc """
  Canonical semantic rectangular region.
  """

  alias ImagePlug.Plan.Geometry.Dimension

  @spaces [:source, :current, :post_orient]
  @enforce_keys [:x, :y, :width, :height, :space]
  defstruct @enforce_keys

  @type space :: :source | :current | :post_orient
  @type t :: %__MODULE__{
          x: Dimension.t(),
          y: Dimension.t(),
          width: Dimension.t(),
          height: Dimension.t(),
          space: space()
        }

  @type error :: {:invalid_region, term()}

  @spec new(keyword()) :: {:ok, t()} | {:error, error()}
  def new(
        x: %Dimension{} = x,
        y: %Dimension{} = y,
        width: %Dimension{} = width,
        height: %Dimension{} = height,
        space: space
      )
      when space in @spaces do
    {:ok, %__MODULE__{x: x, y: y, width: width, height: height, space: space}}
  end

  def new(attrs), do: {:error, {:invalid_region, attrs}}
end
