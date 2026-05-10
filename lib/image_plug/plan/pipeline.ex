defmodule ImagePlug.Plan.Pipeline do
  @moduledoc """
  Ordered image operations separated from source and output intent.
  """

  @enforce_keys [:operations]
  defstruct @enforce_keys

  @type semantic_operation :: ImagePlug.Plan.Operation.semantic_operation()
  @type operation :: semantic_operation() | struct()
  @type t :: %__MODULE__{operations: [operation()]}
end
