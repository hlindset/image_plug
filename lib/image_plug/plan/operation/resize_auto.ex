defmodule ImagePlug.Plan.Operation.ResizeAuto do
  @moduledoc """
  Imgproxy-compatible source-dependent resize semantic intent.
  """

  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity

  @enforce_keys [:size, :enlargement, :guide]
  defstruct @enforce_keys ++
              [
                min_width: nil,
                min_height: nil,
                zoom_x: 1.0,
                zoom_y: 1.0,
                x_offset: {:pixels, 0.0},
                y_offset: {:pixels, 0.0}
              ]

  @type enlargement :: :allow | :deny
  @type offset :: number() | {:pixels, number()} | {:scale, number()}
  @type t :: %__MODULE__{
          size: Size.t(),
          enlargement: enlargement(),
          guide: Gravity.t(),
          min_width: ImagePlug.Plan.Geometry.Dimension.t() | nil,
          min_height: ImagePlug.Plan.Geometry.Dimension.t() | nil,
          zoom_x: pos_integer() | float(),
          zoom_y: pos_integer() | float(),
          x_offset: offset(),
          y_offset: offset()
        }
end
