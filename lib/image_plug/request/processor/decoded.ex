defmodule ImagePlug.Request.Processor.Decoded do
  @moduledoc false

  alias ImagePlug.Request.SourceFormat

  @enforce_keys [:decode_options, :image, :source_format]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          decode_options: keyword(),
          image: Vix.Vips.Image.t(),
          source_format: SourceFormat.source_format()
        }
end
