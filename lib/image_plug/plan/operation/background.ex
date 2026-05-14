defmodule ImagePlug.Plan.Operation.Background do
  @moduledoc """
  Semantic background composition operation.

  The operation describes a color to place behind the current image. Alpha on
  the color is preserved until an output encoder chooses a non-alpha format.
  """

  alias ImagePlug.Plan.Color

  @enforce_keys [:color]
  defstruct @enforce_keys

  @type t :: %__MODULE__{color: Color.t()}
end
