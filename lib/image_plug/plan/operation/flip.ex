defmodule ImagePlug.Plan.Operation.Flip do
  @moduledoc """
  Semantic flip operation.
  """

  @enforce_keys [:axis]
  defstruct @enforce_keys

  @type axis :: :horizontal | :vertical | :both
  @type t :: %__MODULE__{axis: axis()}
end
