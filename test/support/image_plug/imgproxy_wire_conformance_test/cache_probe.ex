defmodule ImgproxyWireConformanceTest.CacheProbe do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Cache]

  @behaviour ImagePlug.Cache

  @impl true
  def get(_key, _opts) do
    send(self(), :cache_lookup)
    :miss
  end

  @impl true
  def put(_key, _entry, _opts) do
    send(self(), :cache_put)
    :ok
  end
end
