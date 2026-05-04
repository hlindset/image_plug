defmodule ImagePlug.ResponseCache do
  @moduledoc false

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.OutputEncoder
  alias ImagePlug.Plan
  alias ImagePlug.TransformState

  @type lookup_result ::
          :disabled
          | {:hit, Entry.t()}
          | {:miss, Key.t()}
          | {:error, term()}

  @spec lookup(Plug.Conn.t(), Plan.t(), String.t(), keyword()) :: lookup_result()
  def lookup(conn, %Plan{} = plan, origin_identity, opts) do
    case Cache.lookup(conn, plan, origin_identity, opts) do
      :disabled -> :disabled
      {:hit, _key, %Entry{} = entry} -> {:hit, entry}
      {:miss, %Key{} = key} -> {:miss, key}
      {:error, {:cache_read, error}} -> {:error, error}
    end
  end

  @spec store(Key.t(), TransformState.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, Entry.t()} | :skipped | {:error, term()}
  def store(%Key{} = key, %TransformState{} = state, response_headers, opts) do
    case OutputEncoder.limited_memory_output(state, opts, Cache.max_body_bytes(opts)) do
      {:ok, %OutputEncoder.EncodedOutput{} = output} ->
        store_output(key, output, response_headers, opts)

      :too_large ->
        :skipped

      {:error, _reason} = error ->
        error
    end
  end

  defp store_output(key, output, response_headers, opts) do
    with {:ok, entry} <- entry(output, response_headers) do
      put_entry(key, entry, opts)
    end
  end

  defp put_entry(key, entry, opts) do
    case Cache.put(key, entry, opts) do
      :ok -> {:ok, entry}
      :skipped -> :skipped
      {:error, _reason} = error -> error
    end
  end

  defp entry(%OutputEncoder.EncodedOutput{} = output, response_headers) do
    case Entry.new(
           body: output.body,
           content_type: output.content_type,
           headers: response_headers,
           created_at: DateTime.utc_now()
         ) do
      {:ok, entry} ->
        {:ok, entry}

      {:error, reason} ->
        {:error,
         {:encode, ArgumentError.exception("invalid cache entry: #{inspect(reason)}"), []}}
    end
  end
end
