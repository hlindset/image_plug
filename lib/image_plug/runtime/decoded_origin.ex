defmodule ImagePlug.Runtime.DecodedOrigin do
  @moduledoc false

  alias ImagePlug.Transform.SourceMetadata

  @enforce_keys [:decode_options, :image, :source_format, :source_metadata]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          decode_options: keyword(),
          image: Vix.Vips.Image.t(),
          source_format: :avif | :webp | :jpeg | :png | nil,
          source_metadata: SourceMetadata.t()
        }
end
