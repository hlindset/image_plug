defmodule ImagePipe.Response.CacheHeaders do
  @moduledoc false

  @enforce_keys [:representation_headers, :headers, :etag]
  defstruct @enforce_keys

  @plug_default_cache_control "max-age=0, private, must-revalidate"

  @type header :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          representation_headers: [header()],
          headers: [header()],
          etag: String.t() | nil
        }

  @doc false
  @spec host_cache_control?([String.t()]) :: boolean()
  def host_cache_control?([]), do: false
  def host_cache_control?([@plug_default_cache_control]), do: false
  def host_cache_control?(_headers), do: true
end
