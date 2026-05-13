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
  alias ImagePlug.Origin.Decoded
  alias ImagePlug.Request.Processor
  alias ImagePlug.Transform
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
          String.t(),
          keyword()
        ) ::
          {:ok, delivery()} | {:error, error()}
  def run(conn, %Plan{} = plan, origin_identity, opts) do
    with {:ok, _pipelines} <- Transform.validate_prefetch_safe_plan(plan),
         :ok <- validate_cache_config(opts) do
      run_with_cache_config(conn, plan, origin_identity, opts)
    else
      {:error, {:cache, reason}} -> {:error, {:cache, reason}}
      {:error, reason} -> {:error, {:processing, reason, []}}
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

  defp run_with_cache_config(conn, plan, origin_identity, opts) do
    case Keyword.get(opts, :cache) do
      nil -> process_uncached(conn, plan, origin_identity, opts)
      _cache -> run_with_cache(conn, plan, origin_identity, opts)
    end
  end

  defp run_with_cache(conn, plan, origin_identity, opts) do
    case Cache.lookup(conn, plan, origin_identity, opts) do
      :disabled ->
        process_uncached(conn, plan, origin_identity, opts)

      {:hit, %Key{} = key, %Entry{} = entry} ->
        handle_cache_hit(conn, plan, origin_identity, key, entry, opts)

      {:miss, %Key{} = key} ->
        process_cache_miss(conn, plan, origin_identity, key, opts)

      {:error, {:cache_read, error}} ->
        {:error, {:cache, error}}
    end
  end

  defp handle_cache_hit(conn, plan, origin_identity, key, entry, opts) do
    case Response.content_disposition(plan.response, entry.content_type) do
      {:ok, _content_disposition} ->
        {:ok, {:cache_entry, entry, plan.response}}

      {:error, error} ->
        handle_cache_delivery_error(conn, plan, origin_identity, key, opts, error)
    end
  end

  defp handle_cache_delivery_error(conn, plan, origin_identity, key, opts, error) do
    if Cache.fail_on_cache_error?(opts) do
      {:error, {:cache, error}}
    else
      process_cache_miss(conn, plan, origin_identity, key, opts)
    end
  end

  defp process_uncached(conn, plan, origin_identity, opts) do
    case process_request(conn, plan, origin_identity, opts) do
      {:ok, final_state, resolved_output, _response_headers} ->
        {:ok, {:image, final_state, resolved_output, plan.response}}

      {:error, error, response_headers} ->
        {:error, {:processing, error, response_headers}}
    end
  end

  defp process_cache_miss(conn, plan, origin_identity, key, opts) do
    case process_request(conn, plan, origin_identity, opts) do
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
    case Encoder.memory_output(
           state.image,
           resolved_output,
           Keyword.put(opts, :max_body_bytes, Cache.max_body_bytes(opts))
         ) do
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
    case Cache.put(key, entry, opts) do
      :ok -> {:ok, entry}
      :skipped -> :skipped
      {:error, _reason} = error -> error
    end
  end

  defp put_cache_entry({:error, reason}, _key, _opts),
    do: {:error, {:invalid_cache_headers, reason}}

  defp process_request(
         conn,
         %Plan{output: %Output{mode: :automatic}} = plan,
         origin_identity,
         opts
       ) do
    policy = Policy.from_output_plan(conn, plan.output, opts)

    case Policy.resolve(policy, nil) do
      {:ok, %Resolved{} = resolved_output} ->
        process_origin_with_output(plan, origin_identity, opts, resolved_output)

      {:error, :source_format_required} ->
        process_source_format_automatic(plan, origin_identity, opts, policy)
    end
  end

  defp process_request(
         conn,
         %Plan{output: %Output{mode: {:explicit, format}}} = plan,
         origin_identity,
         opts
       ) do
    policy = Policy.from_output_plan(conn, plan.output, opts)

    case Policy.resolve(policy, format) do
      {:ok, %Resolved{} = resolved_output} ->
        process_origin_with_output(plan, origin_identity, opts, resolved_output)

      {:error, error} ->
        {:error, error, policy.headers}
    end
  end

  defp process_origin_with_output(plan, origin_identity, opts, %Resolved{} = resolved_output) do
    case Processor.process_origin(plan, origin_identity, opts) do
      {:ok, final_state} ->
        {:ok, final_state, resolved_output, resolved_output.representation_headers}

      {:error, reason} ->
        {:error, reason, resolved_output.representation_headers}
    end
  end

  defp process_decoded_origin_with_output(decoded, plan, opts, %Resolved{} = resolved_output) do
    case Processor.process_decoded_origin(decoded, plan, opts) do
      {:ok, final_state} ->
        {:ok, final_state, resolved_output, resolved_output.representation_headers}

      {:error, reason} ->
        {:error, reason, resolved_output.representation_headers}
    end
  end

  defp process_source_format_automatic(plan, origin_identity, opts, policy) do
    case Processor.fetch_decode_validate_origin_with_source_format(plan, origin_identity, opts) do
      {:ok, %Decoded{} = decoded} ->
        resolve_source_format_automatic(decoded, plan, opts, policy)

      {:error, error} ->
        {:error, error, policy.headers}
    end
  end

  defp resolve_source_format_automatic(%Decoded{} = decoded, plan, opts, policy) do
    case Policy.resolve(policy, decoded.source_format) do
      {:ok, %Resolved{} = resolved_output} ->
        process_decoded_origin_with_output(decoded, plan, opts, resolved_output)

      {:error, error} ->
        {:error, error, policy.headers}
    end
  end
end
