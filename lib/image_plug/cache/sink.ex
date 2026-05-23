defmodule ImagePlug.Cache.Sink do
  @moduledoc false

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key

  @enforce_keys [
    :adapter,
    :key,
    :adapter_opts,
    :metadata,
    :state,
    :size,
    :max_body_bytes,
    :output_format,
    :status
  ]
  defstruct @enforce_keys

  @type status :: :open | :dropped | :committed | :aborted

  @type t :: %__MODULE__{
          adapter: module(),
          key: Key.t(),
          adapter_opts: keyword(),
          metadata: Entry.Metadata.t(),
          state: term(),
          size: non_neg_integer(),
          max_body_bytes: non_neg_integer() | nil,
          output_format: atom(),
          status: status()
        }
end
