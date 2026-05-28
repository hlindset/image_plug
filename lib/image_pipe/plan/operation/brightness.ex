defmodule ImagePipe.Plan.Operation.Brightness do
  @moduledoc """
  Semantic brightness adjustment operation.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: number()}
end
