defmodule ImagePlug.RequestSafetyTest.CacheProbe do
  @moduledoc false

  def get(_key, _opts), do: send(self(), :cache_lookup)
  def put(_key, _entry, _opts), do: send(self(), :cache_put)
end
