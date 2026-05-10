defmodule ImagePlug.Plan.Operation.ResizeFit do
  @moduledoc """
  Semantic resize operation that preserves aspect ratio within a target box.
  """

  alias ImagePlug.Plan.Geometry.Size

  @enforce_keys [:size, :enlargement]
  defstruct @enforce_keys

  @type enlargement :: :allow | :deny
  @type t :: %__MODULE__{size: Size.t(), enlargement: enlargement()}
end
