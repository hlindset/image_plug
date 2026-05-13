defmodule ImagePlug.Runtime.ResponseCache do
  @moduledoc false

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.Output.Encoder
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Response
  alias ImagePlug.Transform.State

  @type lookup_result ::
          :disabled
          | {:hit, Key.t(), Entry.t()}
          | {:miss, Key.t()}
          | {:error, term()}

  @spec lookup(Plug.Conn.t(), Plan.t(), String.t(), keyword()) :: lookup_result()
  def lookup(conn, %Plan{} = plan, origin_identity, opts) do
    case Cache.lookup(conn, plan, origin_identity, opts) do
      :disabled -> :disabled
      {:hit, %Key{} = key, %Entry{} = entry} -> {:hit, key, entry}
      {:miss, %Key{} = key} -> {:miss, key}
      {:error, {:cache_read, error}} -> {:error, error}
    end
  end

  @spec validate_delivery(Entry.t(), Response.t()) :: :ok | {:error, term()}
  def validate_delivery(%Entry{content_type: content_type}, %Response{} = response) do
    case Response.content_disposition(response, content_type) do
      {:ok, _content_disposition} -> :ok
      error -> error
    end
  end

  @spec store(Key.t(), State.t(), Resolved.t(), keyword()) ::
          {:ok, Entry.t()} | :skipped | {:error, term()}
  def store(%Key{} = key, %State{} = state, %Resolved{} = resolved_output, opts) do
    case Encoder.memory_output(
           state.image,
           resolved_output,
           Keyword.put(opts, :max_body_bytes, Cache.max_body_bytes(opts))
         ) do
      {:ok, output} ->
        store_output(key, output, resolved_output.representation_headers, opts)

      :too_large ->
        :skipped

      {:error, _reason} = error ->
        error
    end
  end

  defp store_output(key, output, response_headers, opts) do
    case entry(output, response_headers) do
      {:ok, entry} -> put_entry(key, entry, opts)
      {:error, _reason} = error -> error
    end
  end

  defp put_entry(key, entry, opts) do
    case Cache.put(key, entry, opts) do
      :ok -> {:ok, entry}
      :skipped -> :skipped
      {:error, _reason} = error -> error
    end
  end

  defp entry(output, response_headers) do
    case Entry.cacheable_headers(response_headers) do
      {:ok, headers} ->
        {:ok,
         %Entry{
           body: output.body,
           content_type: output.content_type,
           headers: headers,
           created_at: DateTime.utc_now()
         }}

      {:error, reason} ->
        {:error,
         {:encode, ArgumentError.exception("invalid cache headers: #{inspect(reason)}"), []}}
    end
  end
end
