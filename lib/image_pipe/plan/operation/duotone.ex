defmodule ImagePipe.Plan.Operation.Duotone do
  @moduledoc """
  Semantic two-color luminance mapping operation.
  """

  alias ImagePipe.Plan.Color

  @enforce_keys [:intensity, :shadow, :highlight]
  defstruct [:intensity, :shadow, :highlight]

  @type t :: %__MODULE__{
          intensity: Color.alpha(),
          shadow: Color.t(),
          highlight: Color.t()
        }
end
