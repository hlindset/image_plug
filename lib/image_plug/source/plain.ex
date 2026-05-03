defmodule ImagePlug.Source.Plain do
  @moduledoc """
  Product-neutral source path for plain origin requests.
  """

  @enforce_keys [:path]
  defstruct @enforce_keys

  @type t :: %__MODULE__{path: [String.t()]}
end
