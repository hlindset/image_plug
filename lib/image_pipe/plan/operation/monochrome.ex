defmodule ImagePipe.Plan.Operation.Monochrome do
  @moduledoc """
  Semantic single-color luminance tint operation.
  """

  alias ImagePipe.Plan.Color

  @enforce_keys [:intensity, :color]
  defstruct [:intensity, :color]

  @type t :: %__MODULE__{
          intensity: Color.alpha(),
          color: Color.t()
        }
end
