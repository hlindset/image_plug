defmodule ImagePlug.Cache do
  @moduledoc """
  Coordinates cache lookups and writes for processed image responses.
  """

  require Logger

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.ProcessingRequest

  @shared_cache_option_keys [:key_headers, :key_cookies, :max_body_bytes, :fail_on_cache_error]
  @shared_cache_options_schema NimbleOptions.new!(
                                 key_headers: [
                                   type: {:list, :string}
                                 ],
                                 key_cookies: [
                                   type: {:list, :string}
                                 ],
                                 max_body_bytes: [
                                   type: {:or, [nil, :non_neg_integer]}
                                 ],
                                 fail_on_cache_error: [
                                   type: :boolean
                                 ]
                               )

  @callback get(Key.t(), keyword()) :: {:hit, Entry.t()} | :miss | {:error, term()}
  @callback put(Key.t(), Entry.t(), keyword()) :: :ok | {:error, term()}
  @callback validate_options(keyword()) :: :ok | {:error, term()}

  @optional_callbacks validate_options: 1

  @type lookup_result ::
          :disabled
          | {:hit, Key.t(), Entry.t()}
          | {:miss, Key.t()}
          | {:error, {:cache_read, term()}}

  @doc false
  @spec validate_config(keyword()) :: :ok | {:error, term()}
  def validate_config(opts) when is_list(opts) do
    case cache_config(opts) do
      nil -> :ok
      {:ok, _adapter, _cache_opts} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec validate_config!(keyword()) :: keyword()
  def validate_config!(opts) when is_list(opts) do
    case validate_config(opts) do
      :ok -> opts
      {:error, reason} -> raise ArgumentError, "invalid cache config: #{inspect(reason)}"
    end
  end

  @doc false
  def shared_option_keys, do: @shared_cache_option_keys

  @spec lookup(Plug.Conn.t(), ProcessingRequest.t(), String.t(), keyword()) :: lookup_result()
  def lookup(conn, %ProcessingRequest{} = request, origin_identity, opts) when is_list(opts) do
    lookup(conn, request, origin_identity, opts, [])
  end

  @spec lookup(Plug.Conn.t(), ProcessingRequest.t(), String.t(), keyword(), keyword()) ::
          lookup_result()
  def lookup(conn, %ProcessingRequest{} = request, origin_identity, opts, key_opts)
      when is_list(opts) and is_list(key_opts) do
    case cache_config(opts) do
      nil ->
        :disabled

      {:ok, adapter, cache_opts} ->
        case Key.build(conn, request, origin_identity, Keyword.merge(cache_opts, key_opts)) do
          {:ok, key} ->
            case adapter.get(key, cache_opts) do
              {:hit, %Entry{} = entry} ->
                {:hit, key, entry}

              :miss ->
                {:miss, key}

              {:error, reason} ->
                handle_read_error(reason, key, cache_opts)

              unexpected ->
                handle_read_error({:invalid_adapter_result, unexpected}, key, cache_opts)
            end

          {:error, reason} ->
            {:error, {:cache_read, {:key, reason}}}
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
        if Keyword.keyword?(cache_opts) do
          with :ok <- validate_adapter(adapter),
               {:ok, cache_opts} <- normalize_shared_options(cache_opts),
               :ok <- validate_adapter_options(adapter, adapter_options(cache_opts)) do
            {:ok, adapter, cache_opts}
          end
        else
          {:error, {:invalid_cache_config, {adapter, cache_opts}}}
        end

      invalid ->
        {:error, {:invalid_cache_config, invalid}}
    end
  end

  defp validate_adapter(adapter) when is_atom(adapter) do
    if Code.ensure_loaded?(adapter) and function_exported?(adapter, :get, 2) and
         function_exported?(adapter, :put, 3) do
      :ok
    else
      {:error, {:invalid_cache_config, {:adapter, adapter}}}
    end
  end

  defp validate_adapter(adapter), do: {:error, {:invalid_cache_config, {:adapter, adapter}}}

  defp normalize_shared_options(cache_opts) do
    shared_opts = Keyword.take(cache_opts, @shared_cache_option_keys)

    case NimbleOptions.validate(shared_opts, @shared_cache_options_schema) do
      {:ok, validated_shared_opts} ->
        {:ok, Keyword.merge(cache_opts, validated_shared_opts)}

      {:error, error} ->
        {:error, {:invalid_cache_config, shared_validation_error(error)}}
    end
  end

  defp shared_validation_error(%NimbleOptions.ValidationError{key: key, value: value})
       when key in @shared_cache_option_keys do
    {key, value}
  end

  defp adapter_options(cache_opts), do: Keyword.drop(cache_opts, @shared_cache_option_keys)

  defp validate_adapter_options(adapter, cache_opts) do
    if function_exported?(adapter, :validate_options, 1) do
      case adapter.validate_options(cache_opts) do
        :ok -> :ok
        {:error, reason} -> {:error, {:invalid_cache_config, reason}}
        unexpected -> {:error, {:invalid_cache_config, {:adapter_options, unexpected}}}
      end
    else
      :ok
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
      unexpected -> handle_write_error({:invalid_adapter_result, unexpected}, cache_opts)
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
