defmodule ImagePlug.Parser.Native.CacheRequest do
  @moduledoc false

  defstruct cachebuster: nil

  @type t :: %__MODULE__{cachebuster: String.t() | nil}
end
