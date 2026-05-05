defmodule ImagePlug.Parser.Native.CropRequest do
  @moduledoc false

  @type dimension() :: :auto | {:scale, number()} | ImagePlug.imgp_pixels()

  @type t() :: %__MODULE__{
          width: dimension(),
          height: dimension(),
          gravity: {:anchor, :left | :center | :right, :top | :center | :bottom},
          x_offset: float(),
          y_offset: float()
        }

  defstruct width: :auto,
            height: :auto,
            gravity: {:anchor, :center, :center},
            x_offset: 0.0,
            y_offset: 0.0
end
