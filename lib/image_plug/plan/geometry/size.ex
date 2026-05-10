defmodule ImagePlug.Plan.Geometry.Size do
  @moduledoc """
  Canonical semantic width/height pair with logical-to-physical DPR.
  """

  alias ImagePlug.Plan.Geometry.Dimension

  @enforce_keys [:width, :height, :dpr]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          width: Dimension.t(),
          height: Dimension.t(),
          dpr: pos_integer() | float()
        }

  @type error :: {:invalid_size, term()}

  @spec new(keyword()) :: {:ok, t()} | {:error, error()}
  def new(width: %Dimension{} = width, height: %Dimension{} = height, dpr: dpr)
      when is_number(dpr) and dpr > 0 do
    {:ok, %__MODULE__{width: width, height: height, dpr: dpr}}
  end

  def new(attrs), do: {:error, {:invalid_size, attrs}}
end
