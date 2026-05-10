defmodule ImagePlug.Plan.Operation.Rotate do
  @moduledoc """
  Semantic right-angle rotation operation.
  """

  @enforce_keys [:angle]
  defstruct @enforce_keys

  @type angle :: 0 | 90 | 180 | 270
  @type t :: %__MODULE__{angle: angle()}
end
