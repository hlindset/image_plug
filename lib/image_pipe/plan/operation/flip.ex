defmodule ImagePipe.Plan.Operation.Flip do
  @moduledoc """
  Semantic request to flip the image on one or both axes.
  """

  @enforce_keys [:axis]
  defstruct @enforce_keys

  @type axis :: :horizontal | :vertical | :both
  @type t :: %__MODULE__{axis: axis()}
end
