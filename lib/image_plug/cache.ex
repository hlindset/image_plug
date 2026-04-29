defmodule ImagePlug.Cache do
  @moduledoc """
  Coordinates cache lookups and writes for processed image responses.
  """

  require Logger

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.ProcessingRequest

  @callback get(Key.t(), keyword()) :: {:hit, Entry.t()} | :miss | {:error, term()}
  @callback put(Key.t(), Entry.t(), keyword()) :: :ok | {:error, term()}

  @type lookup_result ::
          :disabled
          | {:hit, Key.t(), Entry.t()}
          | {:miss, Key.t()}
          | {:error, {:cache_read, term()}}

  @spec lookup(Plug.Conn.t(), ProcessingRequest.t(), String.t(), keyword()) :: lookup_result()
  def lookup(conn, %ProcessingRequest{} = request, origin_identity, opts) when is_list(opts) do
    case cache_config(opts) do
      nil ->
        :disabled

      {:ok, adapter, cache_opts} ->
        key = Key.build(conn, request, origin_identity, cache_opts)

        case adapter.get(key, cache_opts) do
          {:hit, %Entry{} = entry} ->
            {:hit, key, entry}

          :miss ->
            {:miss, key}

          {:error, reason} ->
            handle_read_error(reason, key, cache_opts)
        end

      {:error, reason} ->
        {:error, {:cache_read, reason}}
    end
  end

  @spec put(Key.t(), Entry.t(), keyword()) :: :ok | :skipped | {:error, {:cache_write, term()}}
  def put(%Key{} = key, %Entry{} = entry, opts) when is_list(opts) do
    case cache_config(opts) do
      nil ->
        :skipped

      {:ok, adapter, cache_opts} ->
        put_configured(adapter, key, entry, cache_opts)

      {:error, reason} ->
        {:error, {:cache_write, reason}}
    end
  end

  defp cache_config(opts) do
    case Keyword.get(opts, :cache) do
      nil ->
        nil

      {adapter, cache_opts} when is_list(cache_opts) ->
        with :ok <- validate_binary_name_list(cache_opts, :key_headers),
             :ok <- validate_binary_name_list(cache_opts, :key_cookies) do
          {:ok, adapter, cache_opts}
        end

      invalid ->
        {:error, {:invalid_cache_config, invalid}}
    end
  end

  defp validate_binary_name_list(opts, key) do
    value = Keyword.get(opts, key, [])

    if is_list(value) and Enum.all?(value, &is_binary/1) do
      :ok
    else
      {:error, {:invalid_cache_config, {key, value}}}
    end
  end

  defp put_configured(adapter, key, %Entry{body: body} = entry, cache_opts) do
    max_body_bytes = Keyword.get(cache_opts, :max_body_bytes)

    if is_integer(max_body_bytes) and byte_size(body) > max_body_bytes do
      :skipped
    else
      do_put_configured(adapter, key, entry, cache_opts)
    end
  end

  defp do_put_configured(adapter, key, entry, cache_opts) do
    case adapter.put(key, entry, cache_opts) do
      :ok -> :ok
      {:error, reason} -> handle_write_error(reason, cache_opts)
    end
  end

  defp handle_read_error(reason, key, cache_opts) do
    if Keyword.get(cache_opts, :fail_on_cache_error, false) do
      {:error, {:cache_read, reason}}
    else
      Logger.warning("cache read error: #{inspect(reason)}")
      {:miss, key}
    end
  end

  defp handle_write_error(reason, cache_opts) do
    if Keyword.get(cache_opts, :fail_on_cache_error, false) do
      {:error, {:cache_write, reason}}
    else
      Logger.warning("cache write error: #{inspect(reason)}")
      :ok
    end
  end
end
