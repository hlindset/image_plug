defmodule ImagePlug do
  @behaviour Plug

  import Plug.Conn

  require Logger

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.OutputEncoder
  alias ImagePlug.OutputNegotiation
  alias ImagePlug.Origin
  alias ImagePlug.PipelinePlanner
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.RequestRunner
  alias ImagePlug.TransformState

  @type imgp_number() :: integer() | float()
  @type imgp_pixels() :: {:pixels, imgp_number()}
  @type imgp_pct() :: {:percent, imgp_number()}
  @type imgp_scale() :: {:scale, imgp_number(), imgp_number()}
  @type imgp_ratio() :: {imgp_number(), imgp_number()}
  @type imgp_length() :: imgp_pixels() | imgp_pct() | imgp_scale()

  def init(opts), do: Cache.validate_config!(opts)

  def call(%Plug.Conn{} = conn, opts) do
    param_parser = Keyword.fetch!(opts, :param_parser)
    pipeline_planner = Keyword.get(opts, :pipeline_planner, PipelinePlanner)

    with {:ok, request} <- param_parser.parse(conn) |> wrap_parser_error(),
         {:ok, chain} <- pipeline_planner.plan(request) |> wrap_planner_error(),
         {:ok, origin_identity} <- origin_identity(request, opts) |> wrap_origin_error() do
      conn
      |> RequestRunner.run(request, chain, origin_identity, opts)
      |> send_runner_result(conn, opts)
    else
      {:error, {:parser, error}} ->
        param_parser.handle_error(conn, error)

      {:error, {:planner, error}} ->
        param_parser.handle_error(conn, error)

      {:error, {:origin, error}} ->
        send_origin_error(conn, error)
    end
  end

  defp send_runner_result({:ok, {:cache_entry, %Entry{} = entry}}, conn, _opts) do
    send_cache_entry(conn, entry)
  end

  defp send_runner_result(
         {:ok, {:image, %TransformState{} = state, response_headers}},
         conn,
         opts
       ) do
    send_image(conn, state, opts, response_headers)
  end

  defp send_runner_result({:error, {:cache, error}}, conn, _opts) do
    send_cache_error(conn, error)
  end

  defp send_runner_result({:error, {:processing, error, response_headers}}, conn, _opts) do
    handle_processing_error(conn, error, response_headers)
  end

  defp handle_processing_error(conn, error, response_headers) do
    case error do
      {:error, {:transform_error, %TransformState{errors: errors}}} ->
        Logger.info("transform_error(s): #{inspect(errors)}")
        send_transform_error(conn, errors)

      {:error, {:origin, error}} ->
        send_origin_error(conn, error)

      {:error, {:decode, error}} ->
        send_decode_error(conn, error)

      {:error, {:input_limit, error}} ->
        send_input_limit_error(conn, error)

      {:error, :not_acceptable} ->
        send_not_acceptable(conn, response_headers)

      {:error, {:encode, exception, stacktrace}} ->
        handle_encode_exception(exception, stacktrace, conn)

      {:error, {:cache_write, error}} ->
        send_cache_error(conn, error)
    end
  end

  defp origin_identity(%ProcessingRequest{source_kind: :plain, source_path: source_path}, opts) do
    root_url = Keyword.fetch!(opts, :root_url)
    Origin.build_url(root_url, source_path)
  end

  defp origin_identity(%ProcessingRequest{source_kind: source_kind}, _opts) do
    {:error, {:unsupported_source_kind, source_kind}}
  end

  defp wrap_parser_error({:error, _} = error), do: {:error, {:parser, error}}
  defp wrap_parser_error(result), do: result

  defp wrap_planner_error({:error, _} = error), do: {:error, {:planner, error}}
  defp wrap_planner_error(result), do: result

  defp wrap_origin_error({:error, error}), do: {:error, {:origin, error}}
  defp wrap_origin_error(result), do: result

  defp send_origin_error(%Plug.Conn{} = conn, {:bad_status, 404}) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "origin image not found")
  end

  defp send_origin_error(%Plug.Conn{} = conn, _error) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(502, "error fetching origin image")
  end

  defp send_decode_error(%Plug.Conn{} = conn, _error) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(415, "origin response is not a supported image")
  end

  defp send_input_limit_error(%Plug.Conn{} = conn, error) do
    Logger.info("input_limit_error: #{inspect(error)}")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(413, "origin image is too large")
  end

  defp send_transform_error(%Plug.Conn{} = conn, errors) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(422, "invalid image transform: #{inspect(Enum.reverse(errors))}")
  end

  defp send_image(%Plug.Conn{} = conn, %TransformState{} = state, opts, response_headers) do
    with {:ok, mime_type} <- OutputEncoder.mime_type(state) do
      suffix = OutputNegotiation.suffix!(mime_type)
      image_module = Keyword.get(opts, :image_module, Image)

      try do
        stream = image_module.stream!(state.image, suffix: suffix)

        case stream_image(stream, conn, mime_type, response_headers) do
          {:ok, conn} ->
            conn

          {:error, conn} ->
            send_encode_error(conn)

          {:raise, exception, stacktrace, conn} ->
            handle_encode_exception(exception, stacktrace, conn)
        end
      rescue
        exception -> handle_encode_exception(exception, __STACKTRACE__, conn)
      end
    else
      {:error, :not_acceptable} -> send_not_acceptable(conn, response_headers)
      :error -> send_encode_error(conn)
    end
  end

  defp send_cache_entry(%Plug.Conn{} = conn, %Entry{} = entry) do
    with {:ok, headers} <- Entry.normalize_headers(entry.headers) do
      conn =
        Enum.reduce(headers, conn, fn {name, value}, conn ->
          put_resp_header(conn, name, value)
        end)

      conn
      |> put_resp_content_type(entry.content_type, nil)
      |> send_resp(200, entry.body)
    else
      {:error, error} -> send_cache_error(conn, error)
    end
  end

  defp send_cache_error(%Plug.Conn{} = conn, error) do
    Logger.error("cache_error: #{inspect(error)}")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "cache error")
  end

  defp stream_image(stream, %Plug.Conn{} = conn, mime_type, response_headers) do
    reducer = fn data, {status, conn} ->
      try do
        conn =
          case status do
            :pending ->
              conn =
                Enum.reduce(response_headers, conn, fn {name, value}, conn ->
                  put_resp_header(conn, name, value)
                end)

              conn
              |> put_resp_content_type(mime_type, nil)
              |> send_chunked(200)

            :sent ->
              conn
          end

        case chunk(conn, data) do
          {:ok, conn} -> {:suspend, {:sent, conn}}
          {:error, :closed} -> {:halt, {:sent, conn}}
        end
      rescue
        exception -> throw({:encode_exception, exception, __STACKTRACE__, conn})
      end
    end

    continue_stream(
      fn command -> Enumerable.reduce(stream, command, reducer) end,
      {:pending, conn}
    )
  end

  defp continue_stream(continuation, {_status, conn} = acc) do
    case continuation.({:cont, acc}) do
      {:suspended, acc, continuation} -> continue_stream(continuation, acc)
      {:done, {:pending, conn}} -> {:error, conn}
      {:done, {:sent, conn}} -> {:ok, conn}
      {:halted, {_status, conn}} -> {:ok, conn}
    end
  rescue
    exception -> {:raise, exception, __STACKTRACE__, conn}
  catch
    {:encode_exception, exception, stacktrace, conn} -> {:raise, exception, stacktrace, conn}
  end

  defp handle_encode_exception(exception, stacktrace, %Plug.Conn{} = conn) do
    Logger.error("encode_error: #{Exception.format(:error, exception, stacktrace)}")

    if conn.state in [:unset, :set] do
      send_encode_error(conn)
    else
      conn
    end
  end

  defp send_not_acceptable(%Plug.Conn{} = conn, response_headers) do
    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(406, "no acceptable image output format")
  end

  defp put_resp_headers(%Plug.Conn{} = conn, response_headers) do
    Enum.reduce(response_headers, conn, fn {name, value}, conn ->
      put_resp_header(conn, name, value)
    end)
  end

  defp send_encode_error(%Plug.Conn{} = conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "error encoding image")
  end
end
