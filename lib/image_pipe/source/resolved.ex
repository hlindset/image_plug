defmodule ImagePipe.Source.Resolved do
  @moduledoc false

  @enforce_keys [:adapter, :source_kind, :identity, :cache, :fetch]
  defstruct @enforce_keys

  @type cache_policy :: :normal | :skip

  @type t :: %__MODULE__{
          adapter: atom(),
          source_kind: :path | :url | :object | :reference,
          identity: term(),
          cache: cache_policy(),
          fetch: term()
        }
end
