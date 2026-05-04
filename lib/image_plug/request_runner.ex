defmodule ImagePlug.RequestRunner do
  @moduledoc false

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.OutputPlan
  alias ImagePlug.OutputPolicy
  alias ImagePlug.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Processor
  alias ImagePlug.ResponseCache
  alias ImagePlug.TransformChain
  alias ImagePlug.TransformState

  @type delivery() ::
          {:cache_entry, Entry.t()}
          | {:image, TransformState.t(), [{String.t(), String.t()}]}

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
    case pipeline_operations(plan) do
      {:ok, operations} ->
        run_with_cache(conn, plan, operations, origin_identity, opts)

      {:error, reason} ->
        {:error, {:processing, reason, []}}
    end
  end

  defp run_with_cache(
         conn,
         plan,
         operations,
         origin_identity,
         opts
       ) do
    case ResponseCache.lookup(conn, plan, origin_identity, opts) do
      :disabled ->
        process_uncached(conn, plan, operations, origin_identity, opts)

      {:hit, %Entry{} = entry} ->
        {:ok, {:cache_entry, entry}}

      {:miss, %Key{} = key} ->
        process_cache_miss(conn, plan, operations, origin_identity, key, opts)

      {:error, error} ->
        {:error, {:cache, error}}
    end
  end

  defp process_uncached(conn, plan, operations, origin_identity, opts) do
    case process_request(conn, plan, operations, origin_identity, opts) do
      {:ok, final_state, response_headers} ->
        {:ok, {:image, final_state, response_headers}}

      {:error, error, response_headers} ->
        {:error, {:processing, processing_reason(error), response_headers}}
    end
  end

  defp process_cache_miss(conn, plan, operations, origin_identity, key, opts) do
    case process_request(conn, plan, operations, origin_identity, opts) do
      {:ok, final_state, response_headers} ->
        case ResponseCache.store(key, final_state, response_headers, opts) do
          {:ok, entry} -> {:ok, {:cache_entry, entry}}
          :skipped -> {:ok, {:image, final_state, response_headers}}
          error -> {:error, {:processing, processing_reason(error), response_headers}}
        end

      {:error, error, response_headers} ->
        {:error, {:processing, processing_reason(error), response_headers}}
    end
  end

  defp process_request(
         conn,
         %Plan{output: %OutputPlan{mode: :automatic}} = plan,
         operations,
         origin_identity,
         opts
       ) do
    output_policy_request = %ProcessingRequest{format: nil}
    policy = OutputPolicy.from_request(conn, output_policy_request, opts)

    case OutputPolicy.resolve_before_origin(policy) do
      {:selected, format, _reason} ->
        plan
        |> Processor.process_origin(
          TransformChain.append_output(operations, format),
          origin_identity,
          opts
        )
        |> attach_response_headers(policy.headers)

      :needs_source_format ->
        process_source_format_automatic(plan, operations, origin_identity, opts, policy)
    end
  end

  defp process_request(
         _conn,
         %Plan{output: %OutputPlan{mode: {:explicit, format}}} = plan,
         operations,
         origin_identity,
         opts
       ) do
    chain = TransformChain.append_output(operations, format)

    plan
    |> Processor.process_origin(chain, origin_identity, opts)
    |> attach_response_headers([])
  end

  defp attach_response_headers({:ok, final_state}, response_headers),
    do: {:ok, final_state, response_headers}

  defp attach_response_headers(error, response_headers), do: {:error, error, response_headers}

  defp processing_reason({:error, reason}), do: reason
  defp processing_reason(reason), do: reason

  defp process_source_format_automatic(plan, operations, origin_identity, opts, policy) do
    case Processor.fetch_origin_with_source_format(plan, origin_identity, opts) do
      {:ok, origin_response, source_format} ->
        resolve_source_format_automatic(origin_response, source_format, operations, opts, policy)

      error ->
        {:error, error, policy.headers}
    end
  end

  defp resolve_source_format_automatic(origin_response, source_format, operations, opts, policy) do
    case OutputPolicy.resolve_source_format(policy, source_format) do
      {:selected, format, _reason} ->
        decode_source_format_automatic(
          origin_response,
          source_format,
          operations,
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
         operations,
         format,
         opts,
         response_headers
       ) do
    case Processor.decode_validate_origin_response(
           origin_response,
           source_format,
           operations,
           opts
         ) do
      {:ok, %Processor.DecodedOrigin{} = decoded} ->
        decoded
        |> Processor.process_decoded_origin(
          TransformChain.append_output(operations, format),
          opts
        )
        |> attach_response_headers(response_headers)

      error ->
        {:error, error, response_headers}
    end
  end

  defp pipeline_operations(%Plan{pipelines: [%Pipeline{operations: operations}]}),
    do: {:ok, operations}

  defp pipeline_operations(%Plan{pipelines: [_pipeline | _rest]}),
    do: {:error, :unsupported_multiple_pipelines_during_transition}

  defp pipeline_operations(%Plan{pipelines: []}), do: {:error, :empty_pipeline_plan}
end
