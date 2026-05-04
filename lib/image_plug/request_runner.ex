defmodule ImagePlug.RequestRunner do
  @moduledoc false

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.Cache.Material
  alias ImagePlug.OutputPlan
  alias ImagePlug.OutputPolicy
  alias ImagePlug.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.Processor
  alias ImagePlug.ResponseCache
  alias ImagePlug.TransformState

  @type delivery() ::
          {:cache_entry, Entry.t()}
          | {:image, TransformState.t(), OutputPolicy.format(), [{String.t(), String.t()}]}

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
    with {:ok, pipelines} <- Plan.validated_pipelines(plan),
         :ok <- validate_cache_material(pipelines, opts) do
      run_with_cache(conn, plan, origin_identity, opts)
    else
      {:error, reason} -> {:error, {:processing, reason, []}}
    end
  end

  defp validate_cache_material(pipelines, opts) do
    if Keyword.get(opts, :cache) do
      validate_cacheable_operations(pipelines)
    else
      :ok
    end
  end

  defp validate_cacheable_operations(pipelines) do
    case Enum.find_value(pipelines, &uncacheable_operation/1) do
      nil -> :ok
      operation -> {:error, {:invalid_pipeline_operation, operation}}
    end
  end

  defp uncacheable_operation(%Pipeline{operations: operations}) do
    Enum.find(operations, fn {_module, params} -> is_nil(Material.impl_for(params)) end)
  end

  defp run_with_cache(
         conn,
         plan,
         origin_identity,
         opts
       ) do
    case ResponseCache.lookup(conn, plan, origin_identity, opts) do
      :disabled ->
        process_uncached(conn, plan, origin_identity, opts)

      {:hit, %Entry{} = entry} ->
        {:ok, {:cache_entry, entry}}

      {:miss, %Key{} = key} ->
        process_cache_miss(conn, plan, origin_identity, key, opts)

      {:error, error} ->
        {:error, {:cache, error}}
    end
  end

  defp process_uncached(conn, plan, origin_identity, opts) do
    case process_request(conn, plan, origin_identity, opts) do
      {:ok, final_state, resolved_format, response_headers} ->
        {:ok, {:image, final_state, resolved_format, response_headers}}

      {:error, error, response_headers} ->
        {:error, {:processing, processing_reason(error), response_headers}}
    end
  end

  defp process_cache_miss(conn, plan, origin_identity, key, opts) do
    case process_request(conn, plan, origin_identity, opts) do
      {:ok, final_state, resolved_format, response_headers} ->
        case ResponseCache.store(key, final_state, resolved_format, response_headers, opts) do
          {:ok, entry} -> {:ok, {:cache_entry, entry}}
          :skipped -> {:ok, {:image, final_state, resolved_format, response_headers}}
          error -> {:error, {:processing, processing_reason(error), response_headers}}
        end

      {:error, error, response_headers} ->
        {:error, {:processing, processing_reason(error), response_headers}}
    end
  end

  defp process_request(
         conn,
         %Plan{output: %OutputPlan{mode: :automatic}} = plan,
         origin_identity,
         opts
       ) do
    policy = OutputPolicy.from_output_plan(conn, plan.output, opts)

    case OutputPolicy.resolve_before_origin(policy) do
      {:selected, format, _reason} ->
        plan
        |> Processor.process_origin(origin_identity, opts)
        |> attach_resolved_output(format, policy.headers)

      :needs_source_format ->
        process_source_format_automatic(plan, origin_identity, opts, policy)
    end
  end

  defp process_request(
         conn,
         %Plan{output: %OutputPlan{mode: {:explicit, format}}} = plan,
         origin_identity,
         opts
       ) do
    policy = OutputPolicy.from_output_plan(conn, plan.output, opts)

    plan
    |> Processor.process_origin(origin_identity, opts)
    |> attach_resolved_output(format, policy.headers)
  end

  defp attach_resolved_output({:ok, final_state}, format, response_headers),
    do: {:ok, final_state, format, response_headers}

  defp attach_resolved_output(error, _format, response_headers),
    do: {:error, error, response_headers}

  defp processing_reason({:error, reason}), do: reason
  defp processing_reason(reason), do: reason

  defp process_source_format_automatic(plan, origin_identity, opts, policy) do
    case Processor.fetch_origin_with_source_format(plan, origin_identity, opts) do
      {:ok, origin_response, source_format} ->
        resolve_source_format_automatic(origin_response, source_format, plan, opts, policy)

      error ->
        {:error, error, policy.headers}
    end
  end

  defp resolve_source_format_automatic(origin_response, source_format, plan, opts, policy) do
    case OutputPolicy.resolve_source_format(policy, source_format) do
      {:selected, format, _reason} ->
        decode_source_format_automatic(
          origin_response,
          source_format,
          plan,
          format,
          opts,
          policy.headers
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
         format,
         opts,
         response_headers
       ) do
    case Processor.decode_validate_origin_response(
           origin_response,
           source_format,
           plan,
           opts
         ) do
      {:ok, %Processor.DecodedOrigin{} = decoded} ->
        decoded
        |> Processor.process_decoded_origin(plan, opts)
        |> attach_resolved_output(format, response_headers)

      error ->
        {:error, error, response_headers}
    end
  end
end
