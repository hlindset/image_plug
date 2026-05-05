defmodule ImagePlug.Transform.Geometry.DimensionRule do
  @moduledoc false

  @type dimension() :: :auto | ImagePlug.imgp_pixels()
  @type mode() :: :fit | :fill | :force

  @type t() :: %__MODULE__{
          mode: mode(),
          width: dimension(),
          height: dimension(),
          min_width: ImagePlug.imgp_pixels() | nil,
          min_height: ImagePlug.imgp_pixels() | nil,
          zoom_x: float(),
          zoom_y: float(),
          dpr: float(),
          enlarge: boolean()
        }

  defstruct mode: :fit,
            width: :auto,
            height: :auto,
            min_width: nil,
            min_height: nil,
            zoom_x: 1.0,
            zoom_y: 1.0,
            dpr: 1.0,
            enlarge: false
end
