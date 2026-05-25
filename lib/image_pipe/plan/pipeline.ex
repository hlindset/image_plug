defmodule ImagePipe.Plan.Pipeline do
  @moduledoc """
  Ordered image operations separated from source and output intent.
  """

  @enforce_keys [:operations]
  defstruct @enforce_keys

  @type operation ::
          ImagePipe.Plan.Operation.semantic_operation()
          | ImagePipe.Transform.Operation.AutoOrient.t()
          | ImagePipe.Transform.Operation.Rotate.t()
          | ImagePipe.Transform.Operation.Flip.t()
  @type t :: %__MODULE__{operations: [operation()]}
end
