defmodule ImagePipe.Plan.Operation.Pixelate do
  @moduledoc """
  Semantic pixelation operation.
  """

  @enforce_keys [:size]
  defstruct [:size]

  @type t :: %__MODULE__{size: pos_integer()}
end
