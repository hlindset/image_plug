defmodule ImagePlug.Request.SourceSession.Request do
  @moduledoc false

  alias ImagePlug.Output.Policy
  alias ImagePlug.Plan
  alias ImagePlug.Source

  @enforce_keys [:plan, :resolved_source, :output_policy, :opts]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          plan: Plan.t(),
          resolved_source: Source.Resolved.t(),
          output_policy: Policy.t(),
          opts: keyword()
        }
end
