defmodule ImagePlug.Source.Response do
  @moduledoc false

  @enforce_keys [:stream]
  defstruct @enforce_keys

  @type t :: %__MODULE__{stream: Enumerable.t()}
end
