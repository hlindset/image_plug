defmodule ImagePipe.Response.CacheHeaders do
  @moduledoc false

  @enforce_keys [:representation_headers, :headers, :etag]
  defstruct @enforce_keys

  @type header :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          representation_headers: [header()],
          headers: [header()],
          etag: String.t() | nil
        }
end
