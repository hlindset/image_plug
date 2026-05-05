defmodule ImagePlug.Pipeline do
  @moduledoc """
  Ordered image operations separated from source and output intent.
  """

  @enforce_keys [:operations]
  defstruct @enforce_keys

  @type t :: %__MODULE__{operations: ImagePlug.TransformChain.t()}
end
