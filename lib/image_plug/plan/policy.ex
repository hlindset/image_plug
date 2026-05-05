defmodule ImagePlug.Plan.Policy do
  @moduledoc false

  defstruct expires: 0

  @type t :: %__MODULE__{expires: non_neg_integer()}
end
