defmodule ImagePipe.Plan.Operation.Blur do
  @moduledoc """
  Semantic Gaussian blur operation.
  """

  @enforce_keys [:sigma]
  defstruct [:sigma]

  @type t :: %__MODULE__{sigma: float()}
end
