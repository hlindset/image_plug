defmodule ImagePipe.Cache.KeyTest.ForwardingProbe do
  @moduledoc false
  @behaviour ImagePipe.Cache

  def get(_key, _opts), do: :miss
  def open_sink(_key, _metadata, _opts), do: raise("not used")
  def write_chunk(_state, _chunk, _opts), do: raise("not used")
  def commit_sink(_state, _opts), do: raise("not used")
  def abort_sink(_state, _opts), do: :ok
end
