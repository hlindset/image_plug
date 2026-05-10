defmodule ImagePlug.Parser.Imgproxy.CacheRequest do
  @moduledoc false

  defstruct cachebuster: nil

  @type t :: %__MODULE__{cachebuster: String.t() | nil}
end
