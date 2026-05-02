defmodule ImagePlug.ResponseCache do
  @moduledoc false

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.OutputEncoder
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.TransformState

  @type lookup_result ::
          :disabled
          | :skip_cache
          | {:hit, Entry.t()}
          | {:miss, Key.t()}
          | {:error, term()}

  @spec lookup(Plug.Conn.t(), ProcessingRequest.t(), String.t(), keyword()) :: lookup_result()
  def lookup(conn, %ProcessingRequest{} = request, origin_identity, opts) do
    case Cache.lookup(conn, request, origin_identity, opts) do
      :disabled -> :disabled
      :skip_cache -> :skip_cache
      {:hit, _key, %Entry{} = entry} -> {:hit, entry}
      {:miss, %Key{} = key} -> {:miss, key}
      {:error, {:cache_read, error}} -> {:error, error}
    end
  end

  @spec store(Key.t(), TransformState.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, Entry.t()} | {:error, term()}
  def store(%Key{} = key, %TransformState{} = state, response_headers, opts) do
    with {:ok, entry} <- OutputEncoder.cache_entry(state, opts, response_headers),
         put_result when put_result in [:ok, :skipped] <- Cache.put(key, entry, opts) do
      {:ok, entry}
    end
  end
end
