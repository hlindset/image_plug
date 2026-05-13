defmodule ImagePlug.Runtime.DecodedOrigin do
  @moduledoc false

  @enforce_keys [:decode_options, :image, :source_format]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          decode_options: keyword(),
          image: Vix.Vips.Image.t(),
          source_format: :avif | :webp | :jpeg | :png | nil
        }
end
