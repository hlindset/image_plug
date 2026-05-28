defmodule ImagePipe.Plan.Operation.Contrast do
  @moduledoc """
  Semantic contrast adjustment operation.
  """

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: number()}
end
