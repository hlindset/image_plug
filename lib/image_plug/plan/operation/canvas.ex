defmodule ImagePlug.Plan.Operation.Canvas do
  @moduledoc """
  Semantic operation that places the current image onto a canvas.
  """

  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity

  @enforce_keys [:size, :placement, :background, :overflow]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          size: Size.t(),
          placement: Gravity.t(),
          background: :white,
          overflow: :reject
        }
end
