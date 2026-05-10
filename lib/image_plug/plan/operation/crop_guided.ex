defmodule ImagePlug.Plan.Operation.CropGuided do
  @moduledoc """
  Semantic crop operation that crops to a size using a guide.
  """

  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity

  @enforce_keys [:size, :guide]
  defstruct @enforce_keys

  @type t :: %__MODULE__{size: Size.t(), guide: Gravity.t()}
end
