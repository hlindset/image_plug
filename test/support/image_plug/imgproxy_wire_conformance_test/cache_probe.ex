defmodule ImgproxyWireConformanceTest.CacheProbe do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Cache]

  @behaviour ImagePlug.Cache

  @impl true
  def get(key, opts) do
    send(self(), {:source_order, :cache_lookup})
    send(self(), {:cache_lookup, key})

    case Keyword.get(opts, :result, :miss) do
      :miss -> :miss
      {:hit, entry} -> {:hit, entry}
    end
  end

  @impl true
  def put(key, entry, _opts) do
    send(self(), {:source_order, :cache_put})
    send(self(), {:cache_put, key, entry})
    :ok
  end
end
