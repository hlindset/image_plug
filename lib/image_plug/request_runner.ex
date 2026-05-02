defmodule ImagePlug.RequestRunner do
  @moduledoc false

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.OutputSelection
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Processor
  alias ImagePlug.ResponseCache
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
        {:error, {:processing, error, response_headers}}
    end
  end

  defp process_cache_miss(conn, request, chain, origin_identity, key, opts) do
    with {:ok, final_state, response_headers} <-
           process_request(conn, request, chain, origin_identity, opts),
         {:ok, entry} <- ResponseCache.store(key, final_state, response_headers, opts) do
      {:ok, {:cache_entry, entry}}
    else
      {:error, error, response_headers} -> {:error, {:processing, error, response_headers}}
      error -> {:error, {:processing, error, []}}
    end
  end

  defp process_request(
         conn,
         %ProcessingRequest{format: nil} = request,
         chain,
         origin_identity,
         opts
       ) do
    case OutputSelection.preselect(conn, chain, opts) do
      {:ok, %OutputSelection{} = selection} ->
        with {:ok, final_state} <-
               Processor.process_origin(request, selection.chain, origin_identity, opts) do
          {:ok, final_state, selection.headers}
        else
          error -> {:error, error, selection.headers}
        end

      :defer ->
        process_source_format_automatic(conn, request, chain, origin_identity, opts)

      {:error, :not_acceptable} ->
        {:error, {:error, :not_acceptable}, OutputSelection.automatic_headers()}
    end
  end

  defp process_request(_conn, %ProcessingRequest{} = request, chain, origin_identity, opts) do
    with {:ok, final_state} <- Processor.process_origin(request, chain, origin_identity, opts) do
      {:ok, final_state, []}
    else
      error -> {:error, error, []}
    end
  end

  defp process_source_format_automatic(
         conn,
         request,
         chain,
         origin_identity,
         opts
       ) do
    with {:ok, %Processor.DecodedOrigin{} = decoded} <-
           Processor.fetch_decode_validate_origin_with_source_format(
             request,
             origin_identity,
             chain,
             opts
           ) do
      case OutputSelection.negotiate(conn, decoded.source_format, chain, opts) do
        {:ok, %OutputSelection{} = selection} ->
          with {:ok, final_state} <-
                 Processor.process_decoded_origin(decoded, selection.chain, opts) do
            {:ok, final_state, selection.headers}
          else
            error -> {:error, error, selection.headers}
          end

        error ->
          Processor.close_pending_origin(decoded.origin_response)
          {:error, error, OutputSelection.automatic_headers()}
      end
    else
      error -> {:error, error, OutputSelection.automatic_headers()}
    end
  end
end
