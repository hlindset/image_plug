defmodule ImagePlug.Parser.Imgproxy.OutputRequest do
  @moduledoc false

  defstruct format: nil, quality: :default, format_qualities: %{}

  @type format :: :webp | :avif | :jpeg | :png | :best
  @type quality :: :default | {:quality, 1..100}
  @type t :: %__MODULE__{
          format: format() | nil,
          quality: quality(),
          format_qualities: %{optional(format()) => quality()}
        }
end
