defmodule ImagePlug.Plan.Operation.ResizeStretch do
  @moduledoc """
  Semantic resize operation that forces output into the target dimensions.
  """

  alias ImagePlug.Plan.Geometry.Size

  @enforce_keys [:size, :enlargement]
  defstruct @enforce_keys ++ [min_width: nil, min_height: nil, zoom_x: 1.0, zoom_y: 1.0]

  @type enlargement :: :allow | :deny
  @type t :: %__MODULE__{
          size: Size.t(),
          enlargement: enlargement(),
          min_width: ImagePlug.Plan.Geometry.Dimension.t() | nil,
          min_height: ImagePlug.Plan.Geometry.Dimension.t() | nil,
          zoom_x: pos_integer() | float(),
          zoom_y: pos_integer() | float()
        }
end
