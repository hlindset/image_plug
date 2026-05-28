defmodule ImagePipe.Plan.Operation.Sharpen do
  @moduledoc """
  Semantic sharpen operation.
  """

  @enforce_keys [:sigma]
  defstruct [:sigma]

  @type t :: %__MODULE__{sigma: float()}
end
