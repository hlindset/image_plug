defmodule ImagePipe.RequestSafetyTest.CacheProbe do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Cache]

  @behaviour ImagePipe.Cache

  def get(_key, _opts) do
    send(self(), :cache_lookup)
    :miss
  end

  def open_sink(_key, _metadata, _opts), do: {:ok, []}
  def write_chunk(chunks, chunk, _opts), do: {:ok, [chunk | chunks]}

  def commit_sink(_chunks, _opts) do
    send(self(), :cache_put)
    :ok
  end

  def abort_sink(_chunks, _opts), do: :ok
end
