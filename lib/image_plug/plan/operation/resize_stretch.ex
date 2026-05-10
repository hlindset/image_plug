defmodule ImagePlug.Plan.Operation.ResizeStretch do
  @moduledoc """
  Semantic resize operation that forces output into the target dimensions.
  """

  alias ImagePlug.Plan.Geometry.Size

  @enforce_keys [:size, :enlargement]
  defstruct @enforce_keys

  @type enlargement :: :allow | :deny
  @type t :: %__MODULE__{size: Size.t(), enlargement: enlargement()}
end
