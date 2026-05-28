defmodule ImagePipe.Parser.Imgproxy.Effects do
  @moduledoc false

  @type t() :: %__MODULE__{
          blur: float() | nil,
          sharpen: float() | nil,
          pixelate: non_neg_integer() | nil,
          brightness: number() | nil,
          contrast: number() | nil,
          saturation: number() | nil
        }

  defstruct blur: nil,
            sharpen: nil,
            pixelate: nil,
            brightness: nil,
            contrast: nil,
            saturation: nil
end
