defmodule ImagePlug.Plan.Operation.CropRegion do
  @moduledoc """
  Semantic crop operation that crops an explicit region.
  """

  @enforce_keys [:x, :y, :width, :height]
  defstruct @enforce_keys

  @type coordinate :: {:px, non_neg_integer()} | {:ratio, non_neg_integer(), pos_integer()}
  @type dimension :: {:px, pos_integer()} | {:ratio, pos_integer(), pos_integer()}

  @type t :: %__MODULE__{
          x: coordinate(),
          y: coordinate(),
          width: dimension(),
          height: dimension()
        }
end
