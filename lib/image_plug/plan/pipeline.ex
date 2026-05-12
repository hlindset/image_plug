defmodule ImagePlug.Plan.Pipeline do
  @moduledoc """
  Ordered image operations separated from source and output intent.
  """

  @enforce_keys [:operations]
  defstruct @enforce_keys

  @type operation ::
          ImagePlug.Plan.Operation.semantic_operation()
          | ImagePlug.Transform.Operation.AutoOrient.t()
          | ImagePlug.Transform.Operation.Rotate.t()
          | ImagePlug.Transform.Operation.Flip.t()
  @type t :: %__MODULE__{operations: [operation()]}
end
