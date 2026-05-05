defmodule ImagePlug.Runtime.ResponseSender do
  @moduledoc false

  import Plug.Conn

  require Logger

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Output.Format
  alias ImagePlug.Runtime.RequestRunner
  alias ImagePlug.Transform.State

  @spec send_result(
          Plug.Conn.t(),
          RequestRunner.delivery()
          | RequestRunner.error()
          | {:ok, RequestRunner.delivery()}
          | {:error, RequestRunner.error()},
          keyword()
        ) :: Plug.Conn.t()
  def send_result(%Plug.Conn{} = conn, {:cache_entry, %Entry{} = entry}, opts) do
    send_result(conn, {:ok, {:cache_entry, entry}}, opts)
  end

  def send_result(
        %Plug.Conn{} = conn,
        {:image, %State{} = state, resolved_format, response_headers},
        opts
      ) do
    send_result(conn, {:ok, {:image, state, resolved_format, response_headers}}, opts)
  end

  def send_result(%Plug.Conn{} = conn, {:cache, error}, opts) do
    send_result(conn, {:error, {:cache, error}}, opts)
  end

  def send_result(%Plug.Conn{} = conn, {:processing, reason, response_headers}, opts) do
    send_result(conn, {:error, {:processing, reason, response_headers}}, opts)
  end

  def send_result(%Plug.Conn{} = conn, {:ok, {:cache_entry, %Entry{} = entry}}, _opts) do
    send_cache_entry(conn, entry)
  end

  def send_result(
        conn,
        {:ok, {:image, %State{} = state, resolved_format, response_headers}},
        opts
      ) do
    send_image(conn, state, resolved_format, opts, response_headers)
  end

  def send_result(conn, {:error, {:cache, error}}, _opts) do
    send_cache_error(conn, error)
  end

  def send_result(
        conn,
        {:error, {:processing, reason, response_headers}},
        _opts
      ) do
    handle_processing_error(conn, reason, response_headers)
  end

  @spec send_origin_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def send_origin_error(%Plug.Conn{} = conn, error),
    do: send_origin_error(conn, error, [])

  @spec send_origin_error(Plug.Conn.t(), term(), [{String.t(), String.t()}]) :: Plug.Conn.t()
  def send_origin_error(%Plug.Conn{} = conn, {:bad_status, 404}, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "origin image not found")
  end

  def send_origin_error(%Plug.Conn{} = conn, _error, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(502, "error fetching origin image")
  end

  defp handle_processing_error(
         conn,
         {:transform_error, %State{errors: errors}},
         response_headers
       ) do
    Logger.info("transform_error(s): #{inspect(errors)}")
    send_transform_error(conn, response_headers)
  end

  defp handle_processing_error(conn, {:origin, error}, response_headers),
    do: send_origin_error(conn, error, response_headers)

  defp handle_processing_error(conn, {:decode, error}, response_headers),
    do: send_decode_error(conn, error, response_headers)

  defp handle_processing_error(conn, :source_format_required, response_headers),
    do: send_decode_error(conn, :source_format_required, response_headers)

  defp handle_processing_error(conn, {:input_limit, error}, response_headers),
    do: send_input_limit_error(conn, error, response_headers)

  defp handle_processing_error(conn, {:encode, exception, stacktrace}, response_headers),
    do: handle_encode_exception(exception, stacktrace, conn, response_headers)

  defp handle_processing_error(conn, {:cache_write, error}, response_headers),
    do: send_cache_error(conn, error, response_headers)

  defp handle_processing_error(conn, {:config, error}, response_headers),
    do: send_config_error(conn, error, response_headers)

  defp handle_processing_error(conn, :empty_pipeline_plan, response_headers),
    do: send_plan_validation_error(conn, :empty_pipeline_plan, response_headers)

  defp handle_processing_error(conn, {:invalid_pipeline_plan, pipelines}, response_headers),
    do: send_plan_validation_error(conn, {:invalid_pipeline_plan, pipelines}, response_headers)

  defp handle_processing_error(conn, {:invalid_pipeline_operation, operation}, response_headers),
    do:
      send_plan_validation_error(conn, {:invalid_pipeline_operation, operation}, response_headers)

  defp handle_processing_error(
         conn,
         {:unprojectable_operation_for_cache_adapter, operation},
         response_headers
       ),
       do:
         send_plan_validation_error(
           conn,
           {:unprojectable_operation_for_cache_adapter, operation},
           response_headers
         )

  defp send_plan_validation_error(conn, reason, response_headers) do
    Logger.info("plan_validation_error: #{inspect(reason)}")
    send_transform_error(conn, response_headers)
  end

  defp send_decode_error(%Plug.Conn{} = conn, _error, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(415, "origin response is not a supported image")
  end

  defp send_input_limit_error(%Plug.Conn{} = conn, error, response_headers) do
    Logger.info("input_limit_error: #{inspect(error)}")

    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(413, "origin image is too large")
  end

  defp send_transform_error(%Plug.Conn{} = conn, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(422, "invalid image transform")
  end

  defp send_image(
         %Plug.Conn{} = conn,
         %State{} = state,
         resolved_format,
         opts,
         response_headers
       ) do
    stream_encoded_image(conn, state, resolved_format, opts, response_headers)
  end

  defp stream_encoded_image(conn, state, resolved_format, opts, response_headers) do
    image_module = Keyword.get(opts, :image_module, Image)

    try do
      mime_type = Format.mime_type!(resolved_format)
      suffix = Format.suffix!(mime_type)
      stream = image_module.stream!(state.image, suffix: suffix)

      case stream_image(stream, conn, mime_type, response_headers) do
        {:ok, conn} ->
          conn

        {:empty, conn} ->
          send_empty_stream_encode_error(conn, response_headers)

        {:chunk_error, reason, conn} ->
          reason
          |> stream_chunk_error()
          |> handle_encode_exception([], conn, response_headers)

        {:raise, exception, stacktrace, conn} ->
          handle_encode_exception(exception, stacktrace, conn, response_headers)
      end
    rescue
      exception -> handle_encode_exception(exception, __STACKTRACE__, conn, response_headers)
    end
  end

  defp send_cache_entry(%Plug.Conn{} = conn, %Entry{} = entry) do
    case Entry.normalize_headers(entry.headers) do
      {:ok, headers} -> send_normalized_cache_entry(conn, entry, headers)
      {:error, error} -> send_cache_error(conn, error)
    end
  end

  defp send_normalized_cache_entry(%Plug.Conn{} = conn, %Entry{} = entry, headers) do
    conn =
      Enum.reduce(headers, conn, fn {name, value}, conn ->
        put_resp_header(conn, name, value)
      end)

    conn
    |> put_resp_content_type(entry.content_type, nil)
    |> send_resp(200, entry.body)
  end

  defp send_cache_error(%Plug.Conn{} = conn, error),
    do: send_cache_error(conn, error, [])

  defp send_cache_error(%Plug.Conn{} = conn, error, response_headers) do
    Logger.error("cache_error: #{inspect(error)}")

    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "cache error")
  end

  defp send_config_error(%Plug.Conn{} = conn, error, response_headers) do
    Logger.error("config_error: #{inspect(error)}")

    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "configuration error")
  end

  defp stream_image(stream, %Plug.Conn{} = conn, mime_type, response_headers) do
    # Suspend after each chunk so producer exceptions and client disconnects can
    # be handled without forcing the whole encoded image into memory.
    reducer = fn data, acc ->
      case send_stream_chunk(data, acc, mime_type, response_headers) do
        {:ok, acc} -> {:suspend, acc}
        {:halt, acc} -> {:halt, acc}
      end
    end

    continue_stream(
      fn command -> Enumerable.reduce(stream, command, reducer) end,
      {:pending, conn}
    )
  end

  defp send_stream_chunk(data, {status, conn}, mime_type, response_headers) do
    conn =
      case status do
        :pending ->
          conn
          |> put_resp_headers(response_headers)
          |> put_resp_content_type(mime_type, nil)
          |> send_chunked(200)

        :sent ->
          conn
      end

    case chunk(conn, data) do
      {:ok, conn} -> {:ok, {:sent, conn}}
      {:error, :closed} -> {:halt, {:sent, conn}}
      {:error, reason} -> {:halt, {:chunk_error, reason, conn}}
    end
  rescue
    exception -> {:halt, {:raise, exception, __STACKTRACE__, conn}}
  end

  defp continue_stream(continuation, {_status, conn} = acc) do
    case continuation.({:cont, acc}) do
      {:suspended, acc, continuation} -> continue_stream(continuation, acc)
      {:done, {:pending, conn}} -> {:empty, conn}
      {:done, {:sent, conn}} -> {:ok, conn}
      {:halted, {:chunk_error, reason, conn}} -> {:chunk_error, reason, conn}
      {:halted, {:raise, exception, stacktrace, conn}} -> {:raise, exception, stacktrace, conn}
      {:halted, {_status, conn}} -> {:ok, conn}
    end
  rescue
    exception -> {:raise, exception, __STACKTRACE__, conn}
  end

  defp handle_encode_exception(exception, stacktrace, %Plug.Conn{} = conn, response_headers) do
    Logger.error("encode_error: #{Exception.format(:error, exception, stacktrace)}")

    if conn.state in [:unset, :set] do
      send_encode_error(conn, response_headers)
    else
      conn
    end
  end

  defp send_empty_stream_encode_error(%Plug.Conn{} = conn, response_headers) do
    Logger.error("encode_error: image encoder produced an empty stream")
    send_encode_error(conn, response_headers)
  end

  defp stream_chunk_error(reason) do
    RuntimeError.exception("stream chunk failed: #{inspect(reason)}")
  end

  defp put_resp_headers(%Plug.Conn{} = conn, response_headers) do
    Enum.reduce(response_headers, conn, fn {name, value}, conn ->
      put_resp_header(conn, name, value)
    end)
  end

  defp send_encode_error(%Plug.Conn{} = conn, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "error encoding image")
  end
end
