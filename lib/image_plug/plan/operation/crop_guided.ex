defmodule ImagePlug.Plan.Operation.CropGuided do
  @moduledoc """
  Semantic crop operation that crops to a size using a guide.
  """

  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity

  @enforce_keys [:size, :guide]
  defstruct @enforce_keys ++ [x_offset: {:pixels, 0.0}, y_offset: {:pixels, 0.0}]

  @type offset :: number() | {:pixels, number()} | {:scale, number()}
  @type t :: %__MODULE__{
          size: Size.t(),
          guide: Gravity.t(),
          x_offset: offset(),
          y_offset: offset()
        }
end
