defmodule ImagePlug.ProcessorTest.OriginShouldNotFetch do
  @moduledoc false

  def call(_conn, _opts), do: raise("origin should not be fetched")
end
