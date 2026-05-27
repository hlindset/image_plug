defmodule ImagePipe.Source.CacheSemantics do
  @moduledoc """
  Source-owned cache facts used by internal and HTTP cache decisions.

  `byte_identity` seeds must be deterministic, non-secret, and stable across
  nodes for the same source bytes. The core validates the tagged shape but does
  not validate seed contents structurally.
  """

  @enforce_keys [:byte_identity, :stable?]
  defstruct @enforce_keys

  @type byte_identity :: {:strong, term()} | :none

  @type t :: %__MODULE__{
          byte_identity: byte_identity(),
          stable?: boolean()
        }
end
