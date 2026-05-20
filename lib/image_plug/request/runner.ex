defmodule ImagePlug.Request.Runner do
  @moduledoc false

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.Output.Encoder
  alias ImagePlug.Output.Policy
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Response
  alias ImagePlug.Request.Processor
  alias ImagePlug.Request.Processor.Decoded
  alias ImagePlug.Source
  alias ImagePlug.Telemetry
  alias ImagePlug.Transform.State

  @type delivery() ::
          {:cache_entry, Entry.t(), Response.t()}
          | {:image, State.t(), Resolved.t(), Response.t()}

  @type error() ::
          {:cache, term()}
          | {:processing, term(), [{String.t(), String.t()}]}

  @spec run(
          Plug.Conn.t(),
          Plan.t(),
          Source.Resolved.t(),
          keyword()
        ) ::
          {:ok, delivery()} | {:error, error()}
  def run(conn, %Plan{} = plan, %Source.Resolved{} = resolved_source, opts) do
    with :ok <- validate_cache_config(opts) do
      run_with_cache_config(conn, plan, resolved_source, opts)
    else
      {:error, {:cache, reason}} -> {:error, {:cache, reason}}
    end
  end

  defp validate_cache_config(opts) do
    case Keyword.get(opts, :cache) do
      nil ->
        :ok

      _cache ->
        case Cache.validate_config(opts) do
          {:ok, _opts} -> :ok
          {:error, reason} -> {:error, {:cache, reason}}
        end
    end
  end

  defp run_with_cache_config(conn, plan, %Source.Resolved{cache: :skip} = resolved_source, opts),
    do: process_uncached(conn, plan, resolved_source, opts)

  defp run_with_cache_config(conn, plan, %Source.Resolved{cache: :normal} = resolved_source, opts) do
    result =
      Telemetry.span(opts, [:cache, :lookup], cache_lookup_metadata(opts), fn ->
        result =
          case Keyword.get(opts, :cache) do
            nil -> :disabled
            _cache -> Cache.lookup(conn, plan, resolved_source.identity, opts)
          end

        {result, cache_lookup_stop_metadata(result)}
      end)

    case result do
      :disabled ->
        process_uncached(conn, plan, resolved_source, opts)

      {:hit, %Key{} = key, %Entry{} = entry} ->
        handle_cache_hit(conn, plan, resolved_source, key, entry, opts)

      {:miss, %Key{} = key} ->
        process_cache_miss(conn, plan, resolved_source, key, opts)

      {:miss, %Key{} = key, {:cache_read, _error}} ->
        process_cache_miss(conn, plan, resolved_source, key, opts)

      {:error, {:cache_read, error}} ->
        {:error, {:cache, error}}
    end
  end

  defp handle_cache_hit(conn, plan, resolved_source, key, entry, opts) do
    case Response.content_disposition(plan.response, entry.content_type) do
      {:ok, _content_disposition} ->
        {:ok, {:cache_entry, entry, plan.response}}

      {:error, error} ->
        handle_cache_delivery_error(conn, plan, resolved_source, key, opts, error)
    end
  end

  defp handle_cache_delivery_error(conn, plan, resolved_source, key, opts, error) do
    if Cache.fail_on_cache_error?(opts) do
      {:error, {:cache, error}}
    else
      process_cache_miss(conn, plan, resolved_source, key, opts)
    end
  end

  defp process_uncached(conn, plan, resolved_source, opts) do
    case process_request(conn, plan, resolved_source, opts) do
      {:ok, final_state, resolved_output, _response_headers} ->
        {:ok, {:image, final_state, resolved_output, plan.response}}

      {:error, error, response_headers} ->
        {:error, {:processing, error, response_headers}}
    end
  end

  defp process_cache_miss(conn, plan, resolved_source, key, opts) do
    case process_request(conn, plan, resolved_source, opts) do
      {:ok, final_state, resolved_output, response_headers} ->
        case store_cache_entry(key, final_state, resolved_output, opts) do
          {:ok, entry} -> {:ok, {:cache_entry, entry, plan.response}}
          :skipped -> {:ok, {:image, final_state, resolved_output, plan.response}}
          {:error, error} -> {:error, {:processing, error, response_headers}}
        end

      {:error, error, response_headers} ->
        {:error, {:processing, error, response_headers}}
    end
  end

  defp store_cache_entry(%Key{} = key, %State{} = state, %Resolved{} = resolved_output, opts) do
    case encode_cache_entry(state, resolved_output, opts) do
      {:ok, output} ->
        output
        |> cache_entry(resolved_output.representation_headers)
        |> put_cache_entry(key, opts)

      :too_large ->
        :skipped

      {:error, _reason} = error ->
        error
    end
  end

  defp encode_cache_entry(%State{} = state, %Resolved{} = resolved_output, opts) do
    Telemetry.span(opts, [:encode], output_metadata(resolved_output), fn ->
      result =
        Encoder.memory_output(
          state.image,
          resolved_output,
          Keyword.put(opts, :max_body_bytes, Cache.max_body_bytes(opts))
        )

      {result, encode_stop_metadata(result, resolved_output)}
    end)
  end

  defp cache_entry(output, response_headers) do
    with {:ok, headers} <- Entry.cacheable_headers(response_headers) do
      {:ok,
       %Entry{
         body: output.body,
         content_type: output.content_type,
         headers: headers,
         created_at: DateTime.utc_now()
       }}
    end
  end

  defp put_cache_entry({:ok, entry}, key, opts) do
    Telemetry.span(opts, [:cache, :write], %{}, fn ->
      result = Cache.put(key, entry, opts)

      {result, cache_write_stop_metadata(result)}
    end)
    |> case do
      :ok -> {:ok, entry}
      {:ok, {:cache_write, _error}} -> {:ok, entry}
      :skipped -> :skipped
      {:error, _reason} = error -> error
    end
  end

  defp put_cache_entry({:error, reason}, _key, _opts),
    do: {:error, {:invalid_cache_headers, reason}}

  defp process_request(
         conn,
         %Plan{output: %Output{mode: :automatic}} = plan,
         resolved_source,
         opts
       ) do
    policy = Policy.from_output_plan(conn, plan.output, opts)

    case Policy.resolve_before_source_fetch(policy) do
      :needs_source_format ->
        process_source_format_automatic(plan, resolved_source, opts, policy)

      _selection ->
        case resolve_output(policy, nil, plan.output, opts) do
          {:ok, %Resolved{} = resolved_output} ->
            process_source_with_output(plan, resolved_source, opts, resolved_output)

          {:error, error} ->
            {:error, error, policy.headers}
        end
    end
  end

  defp process_request(
         conn,
         %Plan{output: %Output{mode: {:explicit, format}}} = plan,
         resolved_source,
         opts
       ) do
    policy = Policy.from_output_plan(conn, plan.output, opts)

    case resolve_output(policy, format, plan.output, opts) do
      {:ok, %Resolved{} = resolved_output} ->
        process_source_with_output(plan, resolved_source, opts, resolved_output)

      {:error, error} ->
        {:error, error, policy.headers}
    end
  end

  defp process_source_with_output(plan, resolved_source, opts, %Resolved{} = resolved_output) do
    case Processor.process_source(plan, resolved_source, opts) do
      {:ok, final_state} ->
        {:ok, final_state, resolved_output, resolved_output.representation_headers}

      {:error, reason} ->
        {:error, reason, resolved_output.representation_headers}
    end
  end

  defp process_decoded_source_with_output(decoded, plan, opts, %Resolved{} = resolved_output) do
    case Processor.process_decoded_source(decoded, plan, opts) do
      {:ok, final_state} ->
        {:ok, final_state, resolved_output, resolved_output.representation_headers}

      {:error, reason} ->
        {:error, reason, resolved_output.representation_headers}
    end
  end

  defp process_source_format_automatic(plan, resolved_source, opts, policy) do
    case Processor.fetch_decode_validate_source_with_source_format(plan, resolved_source, opts) do
      {:ok, %Decoded{} = decoded} ->
        resolve_source_format_automatic(decoded, plan, opts, policy)

      {:error, error} ->
        {:error, error, policy.headers}
    end
  end

  defp resolve_source_format_automatic(%Decoded{} = decoded, plan, opts, policy) do
    case Policy.resolve_source_format(policy, decoded.source_format) do
      {:selected, _format, _reason} ->
        case resolve_output(policy, decoded.source_format, plan.output, opts) do
          {:ok, %Resolved{} = resolved_output} ->
            process_decoded_source_with_output(decoded, plan, opts, resolved_output)

          {:error, error} ->
            {:error, error, policy.headers}
        end

      {:needs_final_image_alpha, _reason} ->
        process_decoded_source_with_final_alpha_output(decoded, plan, opts, policy)

      {:error, error} ->
        {:error, error, policy.headers}
    end
  end

  defp process_decoded_source_with_final_alpha_output(decoded, plan, opts, policy) do
    case Processor.process_decoded_source(decoded, plan, opts) do
      {:ok, final_state} ->
        has_alpha? = Image.has_alpha?(final_state.image)
        resolved_output = resolve_final_image_alpha_output(policy, has_alpha?, plan.output, opts)

        {:ok, final_state, resolved_output, resolved_output.representation_headers}

      {:error, reason} ->
        {:error, reason, policy.headers}
    end
  end

  defp resolve_output(policy, source_format, %Output{} = output, opts) do
    Telemetry.span(opts, [:output, :negotiate], output_plan_metadata(output), fn ->
      result = Policy.resolve(policy, source_format)

      {result, output_stop_metadata(result, output)}
    end)
  end

  defp resolve_final_image_alpha_output(policy, has_alpha?, %Output{} = output, opts) do
    Telemetry.span(opts, [:output, :negotiate], output_plan_metadata(output), fn ->
      resolved_output = Policy.resolve_final_image_alpha(policy, has_alpha?)

      {resolved_output, output_stop_metadata(resolved_output, output)}
    end)
  end

  defp cache_lookup_metadata(opts) do
    cache =
      case Keyword.get(opts, :cache) do
        nil -> :disabled
        _cache -> nil
      end

    %{cache: cache}
  end

  defp cache_lookup_stop_metadata(:disabled), do: %{result: :ok, cache: :disabled}
  defp cache_lookup_stop_metadata({:hit, %Key{}, %Entry{}}), do: %{result: :ok, cache: :hit}
  defp cache_lookup_stop_metadata({:miss, %Key{}}), do: %{result: :ok, cache: :miss}

  defp cache_lookup_stop_metadata({:miss, %Key{}, {:cache_read, error}}),
    do: %{result: :cache_error, cache: :read_error, error: Telemetry.error(error)}

  defp cache_lookup_stop_metadata({:error, {:cache_read, error}}),
    do: %{result: :cache_error, cache: :read_error, error: Telemetry.error(error)}

  defp cache_write_stop_metadata(:ok), do: %{result: :ok}
  defp cache_write_stop_metadata(:skipped), do: %{result: :ok, cache: :write_skipped}

  defp cache_write_stop_metadata({:ok, {:cache_write, error}}),
    do: %{result: :cache_error, cache: :write_error, error: Telemetry.error(error)}

  defp cache_write_stop_metadata({:error, {:cache_write, error}}),
    do: %{result: :cache_error, cache: :write_error, error: Telemetry.error(error)}

  defp output_plan_metadata(%Output{mode: :automatic}), do: %{output_mode: :automatic}

  defp output_plan_metadata(%Output{mode: {:explicit, format}}),
    do: %{output_mode: :explicit, output_format: format}

  defp output_stop_metadata({:ok, %Resolved{} = resolved_output}, %Output{}),
    do: Map.merge(%{result: :ok}, output_metadata(resolved_output))

  defp output_stop_metadata(%Resolved{} = resolved_output, %Output{}),
    do: Map.merge(%{result: :ok}, output_metadata(resolved_output))

  defp output_stop_metadata({:needs_final_image_alpha, _reason}, %Output{}),
    do: %{result: :ok, output_format: :pending_final_image_alpha}

  defp output_stop_metadata({:error, error}, %Output{}),
    do: %{result: :processing_error, error: Telemetry.error(error)}

  defp output_metadata(%Resolved{format: format}), do: %{output_format: format}

  defp encode_stop_metadata({:ok, _output}, %Resolved{} = resolved_output),
    do: Map.merge(%{result: :ok}, output_metadata(resolved_output))

  defp encode_stop_metadata(:too_large, %Resolved{} = resolved_output),
    do: Map.merge(%{result: :ok, cache: :write_skipped}, output_metadata(resolved_output))

  defp encode_stop_metadata({:error, error}, %Resolved{} = resolved_output),
    do:
      Map.merge(
        %{result: :processing_error, error: Telemetry.error(error)},
        output_metadata(resolved_output)
      )
end
