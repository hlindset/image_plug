defmodule ImagePlug.Plan.Operation.FlattenBackground do
  @moduledoc """
  Semantic operation that composites current alpha over an opaque color.
  """

  @enforce_keys [:color]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          color: ImagePlug.Plan.Color.t()
        }
end
