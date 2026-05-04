defmodule ImagePlug do
  @moduledoc """
  Plug entry point for fetching, transforming, caching, and encoding images.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.ImageFormat
  alias ImagePlug.Origin
  alias ImagePlug.Plan
  alias ImagePlug.RequestRunner
  alias ImagePlug.Source.Plain
  alias ImagePlug.TransformState

  @type imgp_number() :: integer() | float()
  @type imgp_pixels() :: {:pixels, imgp_number()}
  @type imgp_pct() :: {:percent, imgp_number()}
  @type imgp_scale() :: {:scale, imgp_number(), imgp_number()}
  @type imgp_ratio() :: {imgp_number(), imgp_number()}
  @type imgp_length() :: imgp_pixels() | imgp_pct() | imgp_scale()

  @impl Plug
  def init(opts), do: Cache.validate_config!(opts)

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    param_parser = Keyword.fetch!(opts, :param_parser)

    with {:ok, %Plan{} = plan} <- param_parser.parse(conn) |> wrap_parser_error(),
         {:ok, origin_identity} <- origin_identity(plan, opts) |> wrap_origin_error() do
      result = RequestRunner.run(conn, plan, origin_identity, opts)
      send_runner_result(result, conn, opts)
    else
      {:error, {:parser, error}} ->
        param_parser.handle_error(conn, error)

      {:error, {:origin, error}} ->
        send_origin_error(conn, error)
    end
  end

  defp send_runner_result({:ok, {:cache_entry, %Entry{} = entry}}, conn, _opts) do
    send_cache_entry(conn, entry)
  end

  defp send_runner_result(
         {:ok, {:image, %TransformState{} = state, resolved_format, response_headers}},
         conn,
         opts
       ) do
    send_image(conn, state, resolved_format, opts, response_headers)
  end

  defp send_runner_result({:error, {:cache, error}}, conn, _opts) do
    send_cache_error(conn, error)
  end

  defp send_runner_result(
         {:error, {:processing, reason, response_headers}},
         conn,
         _opts
       ) do
    handle_processing_error(conn, reason, response_headers)
  end

  defp handle_processing_error(
         conn,
         {:transform_error, %TransformState{errors: errors}},
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

  defp handle_processing_error(conn, :empty_pipeline_plan, response_headers),
    do: send_migration_guard_error(conn, :empty_pipeline_plan, response_headers)

  defp handle_processing_error(
         conn,
         :unsupported_multiple_pipelines_during_transition,
         response_headers
       ),
       do:
         send_migration_guard_error(
           conn,
           :unsupported_multiple_pipelines_during_transition,
           response_headers
         )

  defp handle_processing_error(
         conn,
         {:unprojectable_operation_for_cache_adapter, operation},
         response_headers
       ),
       do:
         send_migration_guard_error(
           conn,
           {:unprojectable_operation_for_cache_adapter, operation},
           response_headers
         )

  defp send_migration_guard_error(conn, reason, response_headers) do
    Logger.info("migration_guard_error: #{inspect(reason)}")
    send_transform_error(conn, response_headers)
  end

  defp origin_identity(%Plan{source: %Plain{path: source_path}}, opts) do
    root_url = Keyword.fetch!(opts, :root_url)
    Origin.build_url(root_url, source_path)
  end

  defp origin_identity(%Plan{source: source}, _opts) do
    {:error, {:unsupported_source, source}}
  end

  defp wrap_parser_error({:error, _} = error), do: {:error, {:parser, error}}
  defp wrap_parser_error(result), do: result

  defp wrap_origin_error({:error, error}), do: {:error, {:origin, error}}
  defp wrap_origin_error(result), do: result

  defp send_origin_error(%Plug.Conn{} = conn, error),
    do: send_origin_error(conn, error, [])

  defp send_origin_error(%Plug.Conn{} = conn, {:bad_status, 404}, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "origin image not found")
  end

  defp send_origin_error(%Plug.Conn{} = conn, _error, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(502, "error fetching origin image")
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
         %TransformState{} = state,
         resolved_format,
         opts,
         response_headers
       ) do
    stream_encoded_image(conn, state, resolved_format, opts, response_headers)
  end

  defp stream_encoded_image(conn, state, resolved_format, opts, response_headers) do
    image_module = Keyword.get(opts, :image_module, Image)

    try do
      mime_type = ImageFormat.mime_type!(resolved_format)
      suffix = ImageFormat.suffix!(mime_type)
      stream = image_module.stream!(state.image, suffix: suffix)

      case stream_image(stream, conn, mime_type, response_headers) do
        {:ok, conn} ->
          conn

        {:empty, conn} ->
          send_empty_stream_encode_error(conn, response_headers)

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
    end
  rescue
    exception -> {:halt, {:raise, exception, __STACKTRACE__, conn}}
  end

  defp continue_stream(continuation, {_status, conn} = acc) do
    case continuation.({:cont, acc}) do
      {:suspended, acc, continuation} -> continue_stream(continuation, acc)
      {:done, {:pending, conn}} -> {:empty, conn}
      {:done, {:sent, conn}} -> {:ok, conn}
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
