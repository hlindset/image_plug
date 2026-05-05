defmodule ImagePlug.Plan.Cache do
  @moduledoc false

  defstruct cachebuster: nil

  @type t :: %__MODULE__{cachebuster: String.t() | nil}
end
