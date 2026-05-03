defmodule ImagePlug.RequestRunner do
  @moduledoc false

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.OutputPolicy
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
          ProcessingRequest.t(),
          ImagePlug.TransformChain.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, delivery()} | {:error, error()}
  def run(conn, %ProcessingRequest{} = request, chain, origin_identity, opts) do
    run_with_cache(conn, request, chain, origin_identity, opts)
  end

  defp run_with_cache(conn, request, chain, origin_identity, opts) do
    case ResponseCache.lookup(conn, request, origin_identity, opts) do
      status when status in [:disabled, :skip_cache] ->
        process_uncached(conn, request, chain, origin_identity, opts)

      {:hit, %Entry{} = entry} ->
        {:ok, {:cache_entry, entry}}

      {:miss, %Key{} = key} ->
        process_cache_miss(conn, request, chain, origin_identity, key, opts)

      {:error, error} ->
        {:error, {:cache, error}}
    end
  end

  defp process_uncached(conn, request, chain, origin_identity, opts) do
    case process_request(conn, request, chain, origin_identity, opts) do
      {:ok, final_state, response_headers} ->
        {:ok, {:image, final_state, response_headers}}

      {:error, error, response_headers} ->
        {:error, {:processing, processing_reason(error), response_headers}}
    end
  end

  defp process_cache_miss(conn, request, chain, origin_identity, key, opts) do
    with {:ok, final_state, response_headers} <-
           process_request(conn, request, chain, origin_identity, opts) do
      case ResponseCache.store(key, final_state, response_headers, opts) do
        {:ok, entry} -> {:ok, {:cache_entry, entry}}
        :skipped -> {:ok, {:image, final_state, response_headers}}
        error -> {:error, {:processing, processing_reason(error), response_headers}}
      end
    else
      {:error, error, response_headers} ->
        {:error, {:processing, processing_reason(error), response_headers}}
    end
  end

  defp process_request(
         conn,
         %ProcessingRequest{format: nil} = request,
         chain,
         origin_identity,
         opts
       ) do
    policy = OutputPolicy.from_request(conn, request, opts)

    case OutputPolicy.resolve_before_origin(policy) do
      {:selected, format, _reason} ->
        with {:ok, final_state} <-
               Processor.process_origin(
                 request,
                 TransformChain.append_output(chain, format),
                 origin_identity,
                 opts
               ) do
          {:ok, final_state, policy.headers}
        else
          error -> {:error, error, policy.headers}
        end

      :needs_source_format ->
        process_source_format_automatic(request, chain, origin_identity, opts, policy)
    end
  end

  defp process_request(_conn, %ProcessingRequest{} = request, chain, origin_identity, opts) do
    with {:ok, final_state} <- Processor.process_origin(request, chain, origin_identity, opts) do
      {:ok, final_state, []}
    else
      error -> {:error, error, []}
    end
  end

  defp processing_reason({:error, reason}), do: reason
  defp processing_reason(reason), do: reason

  defp process_source_format_automatic(request, chain, origin_identity, opts, policy) do
    with {:ok, origin_response, source_format} <-
           Processor.fetch_origin_with_source_format(request, origin_identity, opts) do
      case OutputPolicy.resolve_source_format(policy, source_format) do
        {:selected, format, _reason} ->
          with {:ok, %Processor.DecodedOrigin{} = decoded} <-
                 Processor.decode_validate_origin_response(
                   origin_response,
                   source_format,
                   chain,
                   opts
                 ),
               {:ok, final_state} <-
                 Processor.process_decoded_origin(
                   decoded,
                   TransformChain.append_output(chain, format),
                   opts
                 ) do
            {:ok, final_state, policy.headers}
          else
            error -> {:error, error, policy.headers}
          end

        {:error, error} ->
          Processor.close_pending_origin(origin_response)
          {:error, error, policy.headers}
      end
    else
      error -> {:error, error, policy.headers}
    end
  end
end
