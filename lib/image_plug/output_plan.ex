defmodule ImagePlug.OutputPlan do
  @moduledoc """
  Requested output intent before runtime format negotiation.
  """

  @enforce_keys [:mode]
  defstruct @enforce_keys

  @type format :: :avif | :webp | :jpeg | :png
  @type t :: %__MODULE__{mode: :automatic | {:explicit, format()}}
end
