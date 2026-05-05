defmodule ImagePlug.Parser.Native.OutputRequest do
  @moduledoc false

  defstruct format: nil, quality: :default, format_qualities: %{}

  @type format :: :webp | :avif | :jpeg | :png | :best
  @type t :: %__MODULE__{
          format: format() | nil,
          quality: :default,
          format_qualities: map()
        }
end
