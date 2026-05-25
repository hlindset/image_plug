defmodule ImagePipe.Cache.Entry.Metadata do
  @moduledoc false

  alias ImagePipe.Cache.Entry

  @enforce_keys [:content_type, :headers, :created_at, :output_format]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          content_type: String.t(),
          headers: [Entry.header()],
          created_at: DateTime.t(),
          output_format: atom()
        }
end
