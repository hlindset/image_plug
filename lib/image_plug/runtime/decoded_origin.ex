defmodule ImagePlug.Runtime.DecodedOrigin do
  @moduledoc false

  alias ImagePlug.Runtime.Origin

  @enforce_keys [:decode_options, :image, :origin_response, :source_format]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          decode_options: keyword(),
          image: Vix.Vips.Image.t(),
          origin_response: Origin.Response.t(),
          source_format: :avif | :webp | :jpeg | :png | nil
        }
end
