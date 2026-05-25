defmodule ImagePipe.Request.SourceSession.Request do
  @moduledoc false

  alias ImagePipe.Cache.Key
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan
  alias ImagePipe.Source

  @enforce_keys [:plan, :resolved_source, :output_policy, :opts]
  defstruct @enforce_keys ++ [cache_key: nil]

  @type t() :: %__MODULE__{
          plan: Plan.t(),
          resolved_source: Source.Resolved.t(),
          output_policy: Policy.t(),
          opts: keyword(),
          cache_key: Key.t() | nil
        }
end
