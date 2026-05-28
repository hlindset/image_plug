defmodule ImagePipe.Plan.Operation.Rotate do
  @moduledoc """
  Semantic request to rotate the image by a right angle.
  """

  @enforce_keys [:angle]
  defstruct @enforce_keys

  @type angle :: 90 | 180 | 270
  @type t :: %__MODULE__{angle: angle()}
end
