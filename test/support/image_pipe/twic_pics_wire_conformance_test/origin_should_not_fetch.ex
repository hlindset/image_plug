defmodule TwicPicsWireConformanceTest.OriginShouldNotFetch do
  @moduledoc false

  use Boundary, top_level?: true, deps: []

  def init(opts), do: opts
  def call(_conn, _opts), do: raise("origin should not fetch")
end
