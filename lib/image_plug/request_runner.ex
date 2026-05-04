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
  alias ImagePlug.Source.Plain
  alias ImagePlug.Transform
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
        legacy_request = legacy_cache_output_request(plan)

        case cache_key_input(legacy_request, operations, opts) do
          {:ok, cache_request} ->
            run_with_cache(
              conn,
              cache_request,
              legacy_request,
              plan,
              operations,
              origin_identity,
              opts
            )

          {:error, reason} ->
            {:error, {:processing, reason, []}}
        end

      {:error, reason} ->
        {:error, {:processing, reason, []}}
    end
  end

  defp run_with_cache(
         conn,
         cache_request,
         legacy_request,
         plan,
         operations,
         origin_identity,
         opts
       ) do
    case ResponseCache.lookup(conn, cache_request, origin_identity, opts) do
      status when status in [:disabled, :skip_cache] ->
        process_uncached(conn, legacy_request, plan, operations, origin_identity, opts)

      {:hit, %Entry{} = entry} ->
        {:ok, {:cache_entry, entry}}

      {:miss, %Key{} = key} ->
        process_cache_miss(conn, legacy_request, plan, operations, origin_identity, key, opts)

      {:error, error} ->
        {:error, {:cache, error}}
    end
  end

  defp process_uncached(conn, legacy_request, plan, operations, origin_identity, opts) do
    case process_request(conn, legacy_request, plan, operations, origin_identity, opts) do
      {:ok, final_state, response_headers} ->
        {:ok, {:image, final_state, response_headers}}

      {:error, error, response_headers} ->
        {:error, {:processing, processing_reason(error), response_headers}}
    end
  end

  defp process_cache_miss(conn, legacy_request, plan, operations, origin_identity, key, opts) do
    case process_request(conn, legacy_request, plan, operations, origin_identity, opts) do
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
         %ProcessingRequest{format: nil} = request,
         %Plan{} = plan,
         operations,
         origin_identity,
         opts
       ) do
    policy = OutputPolicy.from_request(conn, request, opts)

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
         %ProcessingRequest{} = request,
         %Plan{} = plan,
         operations,
         origin_identity,
         opts
       ) do
    chain = TransformChain.append_output(operations, request.format)

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

  defp legacy_cache_output_request(%Plan{source: %Plain{path: path}, output: output}) do
    %ProcessingRequest{
      source_kind: :plain,
      source_path: path,
      format: output_format(output)
    }
  end

  defp cache_key_input(%ProcessingRequest{} = request, operations, opts) do
    if Keyword.get(opts, :cache) do
      project_cache_operations(request, operations)
    else
      {:ok, request}
    end
  end

  defp output_format(%OutputPlan{mode: :automatic}), do: nil
  defp output_format(%OutputPlan{mode: {:explicit, format}}), do: format

  defp project_cache_operations(%ProcessingRequest{} = request, []), do: {:ok, request}

  defp project_cache_operations(%ProcessingRequest{} = request, [operation]) do
    apply_geometry_operation(operation, request)
  end

  defp project_cache_operations(
         %ProcessingRequest{} = request,
         [{Transform.Focus, %Transform.Focus.FocusParams{}} = focus, {Transform.Cover, _} = cover]
       ) do
    case apply_focus_operation(focus, request) do
      {:ok, request} -> apply_geometry_operation(cover, request)
      {:error, _reason} = error -> error
    end
  end

  defp project_cache_operations(%ProcessingRequest{}, operations),
    do: {:error, {:unprojectable_operation_for_cache_adapter, operations}}

  defp apply_geometry_operation(
         {Transform.Scale, %Transform.Scale.ScaleParams{type: :dimensions} = params},
         %ProcessingRequest{} = request
       ) do
    {:ok,
     %ProcessingRequest{
       request
       | resizing_type: :force,
         width: params.width,
         height: params.height
     }}
  end

  defp apply_geometry_operation(
         {Transform.Contain,
          %Transform.Contain.ContainParams{
            type: :dimensions,
            constraint: constraint,
            letterbox: false
          } = params},
         %ProcessingRequest{} = request
       )
       when constraint in [:regular, :max] do
    {:ok,
     %ProcessingRequest{
       request
       | resizing_type: :fit,
         width: params.width,
         height: params.height,
         enlarge: constraint == :regular
     }}
  end

  defp apply_geometry_operation(
         {Transform.Cover,
          %Transform.Cover.CoverParams{type: :dimensions, constraint: constraint} = params},
         %ProcessingRequest{} = request
       )
       when constraint in [:none, :max] do
    {:ok,
     %ProcessingRequest{
       request
       | resizing_type: :fill,
         width: params.width,
         height: params.height,
         enlarge: constraint == :none
     }}
  end

  defp apply_geometry_operation(operation, %ProcessingRequest{}),
    do: {:error, {:unprojectable_operation_for_cache_adapter, operation}}

  defp apply_focus_operation(
         {Transform.Focus, %Transform.Focus.FocusParams{type: {:anchor, x, y} = focus}},
         %ProcessingRequest{} = request
       )
       when x in [:left, :center, :right] and y in [:top, :center, :bottom] do
    {:ok, %ProcessingRequest{request | gravity: request_gravity(focus)}}
  end

  defp apply_focus_operation(
         {Transform.Focus,
          %Transform.Focus.FocusParams{type: {:coordinate, {:percent, x}, {:percent, y}}}},
         %ProcessingRequest{} = request
       )
       when is_number(x) and is_number(y) do
    {:ok, %ProcessingRequest{request | gravity: {:fp, x / 100.0, y / 100.0}}}
  end

  defp apply_focus_operation(operation, %ProcessingRequest{}),
    do: {:error, {:unprojectable_operation_for_cache_adapter, operation}}

  defp request_gravity(gravity), do: gravity
end
