defmodule ImagePlug.Runtime.RequestRunner do
  @moduledoc false

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.Output.Policy
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Runtime.DecodedOrigin
  alias ImagePlug.Runtime.Processor
  alias ImagePlug.Runtime.ResponseCache
  alias ImagePlug.Transform.Material
  alias ImagePlug.Transform.State

  @type delivery() ::
          {:cache_entry, Entry.t()}
          | {:image, State.t(), Resolved.t(), [{String.t(), String.t()}]}

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
    with {:ok, %Plan{} = plan} <- Plan.validate_shape(plan),
         {:ok, pipelines} <- Plan.validated_pipelines(plan),
         {:ok, cache_mode} <- cache_mode(pipelines, opts) do
      case cache_mode do
        :cacheable -> run_with_cache(conn, plan, pipelines, origin_identity, opts)
        :skip_cache -> process_uncached(conn, plan, pipelines, origin_identity, opts)
      end
    else
      {:error, reason} -> {:error, {:processing, reason, []}}
    end
  end

  defp cache_mode(pipelines, opts) do
    case Keyword.get(opts, :cache) do
      nil -> {:ok, :skip_cache}
      _cache -> configured_cache_mode(pipelines, opts)
    end
  end

  defp configured_cache_mode(pipelines, opts) do
    with :ok <- Cache.validate_config(opts) do
      {:ok, cache_mode_for_pipelines(pipelines)}
    end
  end

  defp cache_mode_for_pipelines(pipelines) do
    if cacheable_operations?(pipelines), do: :cacheable, else: :skip_cache
  end

  defp cacheable_operations?(pipelines) do
    Enum.all?(pipelines, fn %Pipeline{operations: operations} ->
      Enum.all?(operations, fn operation -> Material.impl_for(operation) end)
    end)
  end

  defp run_with_cache(
         conn,
         plan,
         pipelines,
         origin_identity,
         opts
       ) do
    case ResponseCache.lookup(conn, plan, origin_identity, opts) do
      :disabled ->
        process_uncached(conn, plan, pipelines, origin_identity, opts)

      {:hit, %Entry{} = entry} ->
        {:ok, {:cache_entry, entry}}

      {:miss, %Key{} = key} ->
        process_cache_miss(conn, plan, pipelines, origin_identity, key, opts)

      {:error, error} ->
        {:error, {:cache, error}}
    end
  end

  defp process_uncached(conn, plan, pipelines, origin_identity, opts) do
    case process_request(conn, plan, pipelines, origin_identity, opts) do
      {:ok, final_state, resolved_output, response_headers} ->
        {:ok, {:image, final_state, resolved_output, response_headers}}

      {:error, error, response_headers} ->
        {:error, {:processing, processing_reason(error), response_headers}}
    end
  end

  defp process_cache_miss(conn, plan, pipelines, origin_identity, key, opts) do
    case process_request(conn, plan, pipelines, origin_identity, opts) do
      {:ok, final_state, resolved_output, response_headers} ->
        case ResponseCache.store(key, final_state, resolved_output, response_headers, opts) do
          {:ok, entry} -> {:ok, {:cache_entry, entry}}
          :skipped -> {:ok, {:image, final_state, resolved_output, response_headers}}
          error -> {:error, {:processing, processing_reason(error), response_headers}}
        end

      {:error, error, response_headers} ->
        {:error, {:processing, processing_reason(error), response_headers}}
    end
  end

  defp process_request(
         conn,
         %Plan{output: %Output{mode: :automatic}} = plan,
         pipelines,
         origin_identity,
         opts
       ) do
    policy = Policy.from_output_plan(conn, plan.output, opts)

    case Policy.resolve(policy, nil) do
      {:ok, %Resolved{} = resolved_output} ->
        plan
        |> Processor.process_origin(pipelines, origin_identity, opts)
        |> attach_resolved_output(resolved_output)

      {:error, :source_format_required} ->
        process_source_format_automatic(plan, pipelines, origin_identity, opts, policy)
    end
  end

  defp process_request(
         conn,
         %Plan{output: %Output{mode: {:explicit, format}}} = plan,
         pipelines,
         origin_identity,
         opts
       ) do
    policy = Policy.from_output_plan(conn, plan.output, opts)

    plan
    |> Processor.process_origin(pipelines, origin_identity, opts)
    |> attach_resolved_output(Policy.resolve(policy, format))
  end

  defp attach_resolved_output({:ok, final_state}, {:ok, %Resolved{} = resolved_output}),
    do: attach_resolved_output({:ok, final_state}, resolved_output)

  defp attach_resolved_output({:ok, final_state}, %Resolved{} = resolved_output),
    do: {:ok, final_state, resolved_output, resolved_output.representation_headers}

  defp attach_resolved_output(error, {:ok, %Resolved{} = resolved_output}),
    do: attach_resolved_output(error, resolved_output)

  defp attach_resolved_output(error, %Resolved{} = resolved_output),
    do: {:error, error, resolved_output.representation_headers}

  defp processing_reason({:error, reason}), do: reason
  defp processing_reason(reason), do: reason

  defp process_source_format_automatic(plan, pipelines, origin_identity, opts, policy) do
    case Processor.fetch_origin_with_source_format(plan, pipelines, origin_identity, opts) do
      {:ok, origin_response, source_format} ->
        resolve_source_format_automatic(
          origin_response,
          source_format,
          plan,
          pipelines,
          opts,
          policy
        )

      error ->
        {:error, error, policy.headers}
    end
  end

  defp resolve_source_format_automatic(
         origin_response,
         source_format,
         plan,
         pipelines,
         opts,
         policy
       ) do
    case Policy.resolve(policy, source_format) do
      {:ok, %Resolved{} = resolved_output} ->
        decode_source_format_automatic(
          origin_response,
          source_format,
          plan,
          pipelines,
          resolved_output,
          opts,
          resolved_output.representation_headers
        )

      {:error, error} ->
        Processor.close_pending_origin(origin_response)
        {:error, error, policy.headers}
    end
  end

  defp decode_source_format_automatic(
         origin_response,
         source_format,
         plan,
         pipelines,
         resolved_output,
         opts,
         response_headers
       ) do
    case Processor.decode_validate_origin_response(
           origin_response,
           source_format,
           plan,
           pipelines,
           opts
         ) do
      {:ok, %DecodedOrigin{} = decoded} ->
        decoded
        |> Processor.process_decoded_origin(pipelines, opts)
        |> attach_resolved_output(resolved_output)

      error ->
        {:error, error, response_headers}
    end
  end
end
