defmodule ImagePlug.Cache do
  @moduledoc """
  Coordinates cache lookups and writes for processed image responses.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePlug.Plan,
      ImagePlug.Output,
      ImagePlug.Transform,
      ImagePlug.Telemetry
    ],
    exports: [
      Entry,
      Key,
      FileSystem
    ]

  require Logger

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.Cache.Sink
  alias ImagePlug.Output.Format
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan
  alias ImagePlug.Telemetry

  @shared_cache_option_keys [:key_headers, :key_cookies, :max_body_bytes]
  @key_option_keys [:auto_avif, :auto_webp]
  @shared_cache_options_schema NimbleOptions.new!(
                                 key_headers: [
                                   type: {:list, :string}
                                 ],
                                 key_cookies: [
                                   type: {:list, :string}
                                 ],
                                 max_body_bytes: [
                                   type: {:or, [nil, :non_neg_integer]}
                                 ]
                               )

  @callback get(Key.t(), keyword()) :: {:hit, Entry.t()} | :miss | {:error, term()}
  @callback open_sink(Key.t(), Entry.Metadata.t(), keyword()) ::
              {:ok, state()} | {:error, term()}
  @callback write_chunk(state(), binary(), keyword()) ::
              {:ok, state()} | {:error, term(), state()}
  @callback commit_sink(state(), keyword()) :: :ok | {:error, term()}
  @callback abort_sink(state(), keyword()) :: :ok | {:error, term()}
  @callback validate_options(keyword()) :: {:ok, keyword()} | {:error, term()}

  @optional_callbacks validate_options: 1

  @type state :: term()
  @opaque sink :: Sink.t()

  @type lookup_result ::
          :disabled
          | {:hit, Key.t(), Entry.t()}
          | {:miss, Key.t()}
          | {:miss, Key.t(), {:cache_read, term()}}
          | {:error, {:cache_read, term()}}

  @doc false
  @spec validate_config(keyword()) :: {:ok, keyword()} | {:error, term()}
  def validate_config(opts) when is_list(opts) do
    normalize_config(opts)
  end

  @doc false
  @spec validate_config!(keyword()) :: keyword()
  def validate_config!(opts) when is_list(opts) do
    case validate_config(opts) do
      {:ok, opts} -> opts
      {:error, reason} -> raise ArgumentError, "invalid cache config: #{inspect(reason)}"
    end
  end

  @doc false
  def shared_option_keys, do: @shared_cache_option_keys

  @doc false
  @spec max_body_bytes(keyword()) :: non_neg_integer() | nil
  def max_body_bytes(opts) when is_list(opts) do
    case cache_config(opts) do
      {:ok, _adapter, cache_opts} -> Keyword.get(cache_opts, :max_body_bytes)
      _other -> nil
    end
  end

  @doc false
  @spec lookup(Plug.Conn.t(), Plan.t(), term(), keyword()) :: lookup_result()
  def lookup(conn, %Plan{} = plan, source_identity, opts) when is_list(opts) do
    case cache_config(opts) do
      nil ->
        :disabled

      {:ok, adapter, cache_opts} ->
        lookup_configured(adapter, conn, plan, source_identity, opts, cache_opts)

      {:error, reason} ->
        {:error, {:cache_read, reason}}
    end
  end

  @doc false
  @spec open_sink(Key.t() | nil, Resolved.t(), keyword()) :: sink() | nil
  def open_sink(nil, %Resolved{}, _opts), do: nil

  def open_sink(%Key{} = key, %Resolved{} = resolved_output, opts) when is_list(opts) do
    with {:ok, adapter, cache_opts} <- cache_config(opts),
         {:ok, metadata} <- metadata(resolved_output) do
      do_open_sink(adapter, key, metadata, cache_opts, opts)
    else
      nil -> nil
      {:error, reason} -> handle_sink_open_error(reason, resolved_output.format, opts)
    end
  end

  @doc false
  @spec write_chunk(sink() | nil, binary(), keyword()) :: sink() | nil
  def write_chunk(nil, _chunk, _opts), do: nil
  def write_chunk(%Sink{status: status} = sink, _chunk, _opts) when status != :open, do: sink

  def write_chunk(%Sink{} = sink, chunk, opts) when is_binary(chunk) do
    case write_chunk_result(sink, chunk, opts) do
      {:ok, sink} -> sink
      :skipped -> nil
      {:error, _reason} -> nil
    end
  end

  @doc false
  @spec commit_sink(sink() | nil, keyword()) :: :ok
  def commit_sink(nil, _opts), do: :ok
  def commit_sink(%Sink{status: status}, _opts) when status != :open, do: :ok
  def commit_sink(%Sink{} = sink, opts), do: do_commit_sink(sink, opts)

  @doc false
  @spec abort_sink(sink() | nil, atom(), keyword()) :: :ok
  def abort_sink(nil, _reason, _opts), do: :ok
  def abort_sink(%Sink{status: status}, _reason, _opts) when status != :open, do: :ok

  def abort_sink(%Sink{} = sink, reason, opts) do
    result = abort_adapter(sink, opts)

    case result do
      :ok -> emit_tee(:abandoned, reason, nil, sink, opts)
      {:error, abort_reason} -> emit_tee(:cleanup_error, reason, abort_reason, sink, opts)
    end

    :ok
  end

  @spec put(Key.t(), Entry.t(), keyword()) ::
          :ok | :skipped | {:ok, {:cache_write, term()}} | {:error, {:cache_write, term()}}
  def put(%Key{} = key, %Entry{} = entry, opts) when is_list(opts) do
    case open_sink_for_entry(key, entry, opts) do
      nil -> :skipped
      :too_large -> :skipped
      %Sink{} = sink -> write_put_body(sink, entry.body, opts)
      {:runtime_error, reason} -> {:ok, {:cache_write, reason}}
      {:error, reason} -> {:error, {:cache_write, reason}}
    end
  end

  defp cache_config(opts) do
    case Keyword.get(opts, :cache) do
      nil ->
        nil

      {adapter, cache_opts} when is_list(cache_opts) ->
        configured_cache(adapter, cache_opts)

      invalid ->
        {:error, {:invalid_cache_config, invalid}}
    end
  end

  defp normalize_config(opts) do
    case Keyword.fetch(opts, :cache) do
      :error ->
        {:ok, opts}

      {:ok, {adapter, cache_opts}} when is_list(cache_opts) ->
        with {:ok, adapter, cache_opts} <- configured_cache(adapter, cache_opts) do
          {:ok, Keyword.put(opts, :cache, {adapter, cache_opts})}
        end

      {:ok, invalid} ->
        {:error, {:invalid_cache_config, invalid}}
    end
  end

  defp lookup_configured(adapter, conn, plan, source_identity, opts, cache_opts) do
    case Key.build(conn, plan, source_identity, key_options(opts, cache_opts)) do
      {:ok, key} -> get_configured(adapter, key, cache_opts)
      {:error, reason} -> {:error, {:cache_read, reason}}
    end
  end

  defp get_configured(adapter, key, cache_opts) do
    case adapter.get(key, cache_opts) do
      {:hit, %Entry{} = entry} ->
        handle_hit(entry, key, cache_opts)

      :miss ->
        {:miss, key}

      {:error, reason} ->
        handle_read_error(reason, key, cache_opts)

      unexpected ->
        handle_read_error({:invalid_adapter_result, unexpected}, key, cache_opts)
    end
  end

  defp handle_hit(%Entry{} = entry, key, cache_opts) do
    case Entry.validate(entry) do
      :ok -> {:hit, key, entry}
      {:error, reason} -> handle_read_error({:invalid_entry, reason}, key, cache_opts)
    end
  end

  defp configured_cache(adapter, cache_opts) do
    if Keyword.keyword?(cache_opts) do
      validate_configured_cache(adapter, cache_opts)
    else
      {:error, {:invalid_cache_config, {adapter, cache_opts}}}
    end
  end

  defp validate_configured_cache(adapter, cache_opts) do
    with :ok <- validate_adapter(adapter),
         {:ok, cache_opts} <- normalize_shared_options(cache_opts),
         {:ok, adapter_opts} <- normalize_adapter_options(adapter, adapter_options(cache_opts)) do
      {:ok, adapter, Keyword.merge(cache_opts, adapter_opts)}
    end
  end

  defp validate_adapter(adapter) when is_atom(adapter) do
    case Code.ensure_loaded(adapter) do
      {:module, _module} -> :ok
      {:error, _reason} -> {:error, {:invalid_cache_config, {:adapter, adapter}}}
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

  defp normalize_adapter_options(adapter, cache_opts) do
    if function_exported?(adapter, :validate_options, 1) do
      case adapter.validate_options(cache_opts) do
        {:ok, normalized_opts} when is_list(normalized_opts) -> {:ok, normalized_opts}
        {:error, reason} -> {:error, {:invalid_cache_config, reason}}
        unexpected -> {:error, {:invalid_cache_config, {:adapter_options, unexpected}}}
      end
    else
      {:ok, cache_opts}
    end
  end

  defp metadata(%Resolved{} = resolved_output) do
    with {:ok, headers} <- Entry.cacheable_headers(resolved_output.response_headers) do
      {:ok,
       %Entry.Metadata{
         content_type: Format.mime_type!(resolved_output.format),
         headers: headers,
         created_at: DateTime.utc_now(),
         output_format: resolved_output.format
       }}
    end
  end

  defp do_open_sink(adapter, %Key{} = key, %Entry.Metadata{} = metadata, cache_opts, opts) do
    case adapter.open_sink(key, metadata, cache_opts) do
      {:ok, adapter_state} ->
        %Sink{
          adapter: adapter,
          key: key,
          adapter_opts: cache_opts,
          metadata: metadata,
          state: adapter_state,
          size: 0,
          max_body_bytes: Keyword.get(cache_opts, :max_body_bytes),
          output_format: metadata.output_format,
          status: :open
        }

      {:error, reason} ->
        handle_sink_open_error(reason, metadata.output_format, opts)

      unexpected ->
        handle_sink_open_error(
          {:invalid_adapter_result, unexpected},
          metadata.output_format,
          opts
        )
    end
  end

  defp handle_sink_open_error(reason, output_format, opts) do
    Logger.warning("cache sink open error: #{inspect(reason)}")
    emit_tee(:write_error, :open, reason, output_format, opts)
    nil
  end

  defp handle_put_sink_open_error(reason, output_format, opts) do
    Logger.warning("cache sink open error: #{inspect(reason)}")
    emit_tee(:write_error, :open, reason, output_format, opts)
    {:runtime_error, reason}
  end

  defp write_chunk_result(%Sink{} = sink, chunk, opts) do
    size = sink.size + byte_size(chunk)

    if too_large?(size, sink.max_body_bytes) do
      emit_abort_cleanup(abort_adapter(sink, opts), :too_large, sink, opts)
      emit_tee(:write_skipped, :too_large, nil, sink, opts)
      :skipped
    else
      do_write_chunk(%{sink | size: size}, chunk, opts)
    end
  end

  defp do_write_chunk(%Sink{} = sink, chunk, opts) do
    case sink.adapter.write_chunk(sink.state, chunk, sink.adapter_opts) do
      {:ok, adapter_state} ->
        {:ok, %{sink | state: adapter_state}}

      {:error, reason, adapter_state} ->
        sink = %{sink | state: adapter_state}
        emit_abort_cleanup(abort_adapter(sink, opts), :write_error, sink, opts)
        Logger.warning("cache sink write error: #{inspect(reason)}")
        emit_tee(:write_error, :write, reason, sink, opts)
        {:error, reason}

      unexpected ->
        reason = {:invalid_adapter_result, unexpected}
        emit_abort_cleanup(abort_adapter(sink, opts), :write_error, sink, opts)
        Logger.warning("cache sink write error: #{inspect(reason)}")
        emit_tee(:write_error, :write, reason, sink, opts)
        {:error, reason}
    end
  end

  defp do_commit_sink(%Sink{} = sink, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :write], %{}, fn ->
      result = sink.adapter.commit_sink(sink.state, sink.adapter_opts)
      {:ok, commit_stop_metadata(result, sink)}
    end)

    :ok
  end

  defp commit_put_sink(%Sink{} = sink, opts) do
    result = sink.adapter.commit_sink(sink.state, sink.adapter_opts)
    _result = emit_write_stop(result, sink, opts)

    case result do
      :ok -> :ok
      {:error, reason} -> {:ok, {:cache_write, reason}}
      unexpected -> {:ok, {:cache_write, {:invalid_adapter_result, unexpected}}}
    end
  end

  defp emit_write_stop(result, %Sink{} = sink, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :write], %{}, fn ->
      {:ok, commit_stop_metadata(result, sink)}
    end)
  end

  defp commit_stop_metadata(:ok, %Sink{} = sink),
    do: %{result: :ok, cache: :write, output_format: sink.output_format}

  defp commit_stop_metadata({:error, reason}, %Sink{} = sink) do
    Logger.warning("cache sink commit error: #{inspect(reason)}")

    %{
      result: :cache_error,
      cache: :write_error,
      error: Telemetry.error(reason),
      output_format: sink.output_format
    }
  end

  defp commit_stop_metadata(unexpected, %Sink{} = sink) do
    reason = {:invalid_adapter_result, unexpected}
    Logger.warning("cache sink commit error: #{inspect(reason)}")

    %{
      result: :cache_error,
      cache: :write_error,
      error: Telemetry.error(reason),
      output_format: sink.output_format
    }
  end

  defp abort_adapter(%Sink{} = sink, _opts) do
    case sink.adapter.abort_sink(sink.state, sink.adapter_opts) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      unexpected -> {:error, {:invalid_adapter_result, unexpected}}
    end
  end

  defp emit_abort_cleanup(:ok, _reason, _sink, _opts), do: :ok

  defp emit_abort_cleanup({:error, cleanup_reason}, reason, %Sink{} = sink, opts) do
    emit_tee(:cleanup_error, reason, cleanup_reason, sink, opts)
  end

  defp emit_tee(cache_status, reason, error, %Sink{} = sink, opts) do
    emit_tee(cache_status, reason, error, sink.output_format, opts)
  end

  defp emit_tee(cache_status, reason, error, output_format, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :tee], %{}, fn ->
      {:ok, tee_stop_metadata(cache_status, reason, error, output_format)}
    end)
  end

  defp tee_stop_metadata(:write_error, _reason, error, output_format),
    do: %{
      result: :cache_error,
      cache: :write_error,
      error: Telemetry.error(error),
      output_format: output_format
    }

  defp tee_stop_metadata(:cleanup_error, _reason, error, output_format),
    do: %{
      result: :cache_error,
      cache: :cleanup_error,
      error: Telemetry.error(error),
      output_format: output_format
    }

  defp tee_stop_metadata(cache_status, reason, _error, output_format),
    do: %{
      result: :ok,
      cache: cache_status,
      reason: reason,
      output_format: output_format
    }

  defp open_sink_for_entry(%Key{} = key, %Entry{} = entry, opts) do
    with {:ok, adapter, cache_opts} <- cache_config(opts),
         false <- too_large?(byte_size(entry.body), Keyword.get(cache_opts, :max_body_bytes)),
         {:ok, output_format} <- Format.format(entry.content_type),
         {:ok, headers} <- Entry.cacheable_headers(entry.headers) do
      metadata = %Entry.Metadata{
        content_type: entry.content_type,
        headers: headers,
        created_at: entry.created_at,
        output_format: output_format
      }

      do_open_put_sink(adapter, key, metadata, cache_opts, opts)
    else
      nil -> nil
      true -> :too_large
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_open_put_sink(adapter, %Key{} = key, %Entry.Metadata{} = metadata, cache_opts, opts) do
    case adapter.open_sink(key, metadata, cache_opts) do
      {:ok, adapter_state} ->
        %Sink{
          adapter: adapter,
          key: key,
          adapter_opts: cache_opts,
          metadata: metadata,
          state: adapter_state,
          size: 0,
          max_body_bytes: Keyword.get(cache_opts, :max_body_bytes),
          output_format: metadata.output_format,
          status: :open
        }

      {:error, reason} ->
        handle_put_sink_open_error(reason, metadata.output_format, opts)

      unexpected ->
        handle_put_sink_open_error(
          {:invalid_adapter_result, unexpected},
          metadata.output_format,
          opts
        )
    end
  end

  defp write_put_body(%Sink{} = sink, body, opts) do
    case write_chunk_result(sink, body, opts) do
      {:ok, sink} -> commit_put_sink(sink, opts)
      :skipped -> :skipped
      {:error, reason} -> {:ok, {:cache_write, reason}}
    end
  end

  defp too_large?(_size, nil), do: false
  defp too_large?(size, max_body_bytes), do: size > max_body_bytes

  defp handle_read_error(reason, key, _cache_opts) do
    Logger.warning("cache read error: #{inspect(reason)}")
    {:miss, key, {:cache_read, reason}}
  end

  defp key_options(opts, cache_opts) do
    cache_opts
    |> Keyword.take([:key_headers, :key_cookies])
    |> Keyword.merge(Keyword.take(opts, @key_option_keys))
  end
end
