defmodule ImagePlug.Transform.Derivation do
  @moduledoc """
  Source-aware lowering fact recorded after final cache lookup.
  """

  @enforce_keys [:code, :value, :pipeline_index, :operation_index]
  defstruct [:code, :value, :pipeline_index, :operation_index, material?: false, details: %{}]

  @type t :: %__MODULE__{
          code: atom(),
          value: term(),
          pipeline_index: non_neg_integer(),
          operation_index: non_neg_integer(),
          material?: false,
          details: map()
        }
end
