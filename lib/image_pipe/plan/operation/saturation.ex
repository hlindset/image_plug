defmodule ImagePipe.Plan.Operation.Saturation do
  @moduledoc """
  Semantic saturation adjustment operation.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: number()}
end
