defmodule ImagePlug.Plan.Operation.ResizeCover do
  @moduledoc """
  Semantic resize operation that covers a target box and crops by guide.
  """

  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity

  @enforce_keys [:size, :enlargement, :guide]
  defstruct @enforce_keys

  @type enlargement :: :allow | :deny
  @type t :: %__MODULE__{size: Size.t(), enlargement: enlargement(), guide: Gravity.t()}
end
