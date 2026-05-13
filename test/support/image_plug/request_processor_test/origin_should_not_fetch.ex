defmodule ImagePlug.Request.ProcessorTest.OriginShouldNotFetch do
  @moduledoc false

  @spec call(Plug.Conn.t(), keyword()) :: no_return()
  def call(_conn, _opts), do: raise("origin should not be fetched")
end
