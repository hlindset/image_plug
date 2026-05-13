defmodule ImagePlug.Runtime.RequestRunner do
  @moduledoc false

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.Output.Policy
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Response
  alias ImagePlug.Runtime.DecodedOrigin
  alias ImagePlug.Runtime.Processor
  alias ImagePlug.Runtime.ResponseCache
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
          {:error, _reason} = error -> error
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
    case ResponseCache.lookup(conn, plan, origin_identity, opts) do
      :disabled ->
        process_uncached(conn, plan, origin_identity, opts)

      {:hit, %Key{} = key, %Entry{} = entry} ->
        handle_cache_hit(conn, plan, origin_identity, key, entry, opts)

      {:miss, %Key{} = key} ->
        process_cache_miss(conn, plan, origin_identity, key, opts)

      {:error, error} ->
        {:error, {:cache, error}}
    end
  end

  defp handle_cache_hit(conn, plan, origin_identity, key, entry, opts) do
    case ResponseCache.validate_delivery(entry, plan.response) do
      :ok ->
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
        case ResponseCache.store(key, final_state, resolved_output, opts) do
          {:ok, entry} -> {:ok, {:cache_entry, entry, plan.response}}
          :skipped -> {:ok, {:image, final_state, resolved_output, plan.response}}
          {:error, error} -> {:error, {:processing, error, response_headers}}
        end

      {:error, error, response_headers} ->
        {:error, {:processing, error, response_headers}}
    end
  end

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
      {:ok, %DecodedOrigin{} = decoded} ->
        resolve_source_format_automatic(decoded, plan, opts, policy)

      {:error, error} ->
        {:error, error, policy.headers}
    end
  end

  defp resolve_source_format_automatic(%DecodedOrigin{} = decoded, plan, opts, policy) do
    case Policy.resolve(policy, decoded.source_format) do
      {:ok, %Resolved{} = resolved_output} ->
        process_decoded_origin_with_output(decoded, plan, opts, resolved_output)

      {:error, error} ->
        {:error, error, policy.headers}
    end
  end
end
