defmodule ImagePlug.Plan.Operation.CropRegion do
  @moduledoc """
  Semantic crop operation that crops an explicit region.
  """

  alias ImagePlug.Plan.Geometry.Region

  @enforce_keys [:region]
  defstruct @enforce_keys

  @type t :: %__MODULE__{region: Region.t()}
end
