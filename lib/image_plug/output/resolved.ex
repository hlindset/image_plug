defmodule ImagePlug.Output.Resolved do
  @moduledoc false

  @enforce_keys [:format, :quality, :representation_headers]
  defstruct @enforce_keys

  @type format :: :avif | :webp | :jpeg | :png
  @type quality :: :default | {:quality, 1..100}
  @type t :: %__MODULE__{
          format: format(),
          quality: quality(),
          representation_headers: [{String.t(), String.t()}]
        }
end
