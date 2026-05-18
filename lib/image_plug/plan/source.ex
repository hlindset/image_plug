defmodule ImagePlug.Plan.Source do
  @moduledoc """
  Product-neutral source identifiers produced by parsers.
  """

  alias ImagePlug.Plan.Source

  @type t :: Source.Path.t() | Source.URL.t() | Source.Object.t() | Source.Reference.t()
end
