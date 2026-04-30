defmodule ImagePlug do
  @behaviour Plug

  import Plug.Conn

  require Logger

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.DecodePlanner
  alias ImagePlug.ImageMaterializer
  alias ImagePlug.OutputNegotiation
  alias ImagePlug.Origin
  alias ImagePlug.PipelinePlanner
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.TransformChain
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
      dispatch_request(conn, request, chain, origin_identity, opts)
    else
      {:error, {:parser, error}} ->
        param_parser.handle_error(conn, error)

      {:error, {:planner, error}} ->
        param_parser.handle_error(conn, error)

      {:error, {:origin, error}} ->
        send_origin_error(conn, error)
    end
  end

  defp dispatch_request(conn, request, chain, origin_identity, opts) do
    case Cache.lookup(conn, request, origin_identity, opts) do
      :disabled ->
        process_uncached(conn, request, chain, origin_identity, opts)

      {:hit, _key, %Entry{} = entry} ->
        send_cache_entry(conn, entry)

      {:miss, %Key{} = key} ->
        process_cache_miss(conn, request, chain, origin_identity, key, opts)

      {:error, {:cache_read, error}} ->
        send_cache_error(conn, error)
    end
  end

  defp process_uncached(conn, request, chain, origin_identity, opts) do
    with {:ok, final_state} <- process_origin(request, chain, origin_identity, opts) do
      send_image(conn, final_state, opts)
    else
      {:error, {:transform_error, %TransformState{errors: errors}}} ->
        Logger.info("transform_error(s): #{inspect(errors)}")
        send_transform_error(conn, errors)

      {:error, {:origin, error}} ->
        send_origin_error(conn, error)

      {:error, {:decode, error}} ->
        send_decode_error(conn, error)

      {:error, {:input_limit, error}} ->
        send_input_limit_error(conn, error)
    end
  end

  defp process_cache_miss(conn, request, chain, origin_identity, key, opts) do
    with {:ok, final_state} <- process_origin(request, chain, origin_identity, opts),
         {:ok, entry} <- encode_cache_entry(conn, final_state, opts),
         put_result when put_result in [:ok, :skipped] <- Cache.put(key, entry, opts) do
      send_cache_entry(conn, entry)
    else
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
        send_not_acceptable(conn)

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

  defp process_origin(request, chain, origin_identity, opts) do
    decode_options = DecodePlanner.open_options(chain)

    with {:ok, origin_response} <-
           fetch_origin(request, origin_identity, opts) |> wrap_origin_error(),
         {:ok, image} <-
           decode_origin_response(origin_response, decode_options, opts)
           |> wrap_origin_decode_error(),
         :ok <- validate_input_image(image, opts) |> wrap_input_limit_error(),
         {:ok, final_state} <- TransformChain.execute(%TransformState{image: image}, chain),
         {:ok, final_state} <-
           materialize_before_delivery(final_state, origin_response, decode_options, opts) do
      {:ok, final_state}
    end
  end

  defp decode_origin_response(%Origin.Response{} = origin_response, decode_options, opts) do
    image_open_module = Keyword.get(opts, :image_open_module, Image)

    case image_open_module.open(origin_response.stream, decode_options) do
      {:ok, image} ->
        case Origin.stream_status(origin_response) do
          {:error, reason} -> {:error, {:origin, reason}}
          :done -> {:ok, image}
          :pending -> {:ok, image}
        end

      {:error, decode_error} ->
        case Origin.stream_status(origin_response) do
          {:error, reason} -> {:error, {:origin, reason}}
          :done -> {:error, decode_error}
          :pending -> {:error, decode_error}
        end
    end
  end

  defp materialize_before_delivery(
         %TransformState{} = state,
         %Origin.Response{} = origin_response,
         decode_options,
         opts
       ) do
    if Keyword.fetch!(decode_options, :access) == :sequential do
      materializer = Keyword.get(opts, :image_materializer_module, ImageMaterializer)

      case materializer.materialize(state.image) do
        {:ok, materialized_image} ->
          case Origin.require_stream_status(origin_response) do
            :done ->
              {:ok, TransformState.set_image(state, materialized_image)}

            {:error, reason} ->
              {:error, {:origin, reason}}
          end

        {:error, materialize_error} ->
          case Origin.stream_status(origin_response) do
            {:error, reason} ->
              {:error, {:origin, reason}}

            :done ->
              {:error, {:decode, materialize_error}}

            :pending ->
              Origin.close(origin_response)
              {:error, {:decode, materialize_error}}
          end
      end
    else
      {:ok, state}
    end
  end

  defp fetch_origin(%ProcessingRequest{source_kind: :plain}, origin_identity, opts) do
    Origin.fetch(origin_identity, origin_req_options(opts))
  end

  defp origin_req_options(opts) do
    opts
    |> Keyword.get(:origin_req_options, [])
    |> put_origin_req_option(:max_body_bytes, Keyword.fetch(opts, :max_body_bytes))
    |> put_origin_req_option(:receive_timeout, Keyword.fetch(opts, :origin_receive_timeout))
    |> put_origin_req_option(:max_redirects, Keyword.fetch(opts, :origin_max_redirects))
  end

  defp put_origin_req_option(req_options, key, {:ok, value}),
    do: Keyword.put(req_options, key, value)

  defp put_origin_req_option(req_options, _key, :error), do: req_options

  defp wrap_parser_error({:error, _} = error), do: {:error, {:parser, error}}
  defp wrap_parser_error(result), do: result

  defp wrap_planner_error({:error, _} = error), do: {:error, {:planner, error}}
  defp wrap_planner_error(result), do: result

  defp wrap_origin_error({:error, error}), do: {:error, {:origin, error}}
  defp wrap_origin_error(result), do: result

  defp wrap_decode_error({:error, _} = error), do: {:error, {:decode, error}}
  defp wrap_decode_error(result), do: result

  defp wrap_origin_decode_error({:error, {:origin, error}}), do: {:error, {:origin, error}}
  defp wrap_origin_decode_error(result), do: wrap_decode_error(result)

  defp validate_input_image(image, opts) do
    max_input_pixels = Keyword.get(opts, :max_input_pixels, 40_000_000)
    pixel_count = Image.width(image) * Image.height(image)

    if pixel_count <= max_input_pixels do
      :ok
    else
      {:error, {:too_many_input_pixels, pixel_count, max_input_pixels}}
    end
  end

  defp wrap_input_limit_error(:ok), do: :ok
  defp wrap_input_limit_error({:error, error}), do: {:error, {:input_limit, error}}

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

  defp send_image(%Plug.Conn{} = conn, %TransformState{image: image, output: :blurhash}, _opts) do
    case Image.Blurhash.encode(image) do
      {:ok, blurhash} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(200, blurhash)

      {:error, _} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(500, "error generating blurhash for image")
    end
  end

  defp send_image(%Plug.Conn{} = conn, %TransformState{} = state, opts) do
    with {:ok, mime_type} <- output_mime_type(conn, state) do
      suffix = OutputNegotiation.suffix!(mime_type)
      image_module = Keyword.get(opts, :image_module, Image)

      try do
        stream = image_module.stream!(state.image, suffix: suffix)

        case stream_image(stream, conn, mime_type, response_headers_for_state(state)) do
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
      {:error, :not_acceptable} -> send_not_acceptable(conn)
    end
  end

  defp encode_cache_entry(
         %Plug.Conn{} = _conn,
         %TransformState{image: image, output: :blurhash},
         _opts
       ) do
    case Image.Blurhash.encode(image) do
      {:ok, blurhash} ->
        {:ok,
         Entry.new!(
           body: blurhash,
           content_type: "text/plain",
           headers: [],
           created_at: DateTime.utc_now()
         )}

      {:error, error} ->
        {:error, {:encode, error, []}}
    end
  end

  defp encode_cache_entry(%Plug.Conn{} = conn, %TransformState{} = state, opts) do
    with {:ok, mime_type} <- output_mime_type(conn, state) do
      suffix = OutputNegotiation.suffix!(mime_type)
      image_module = Keyword.get(opts, :image_module, Image)

      try do
        body = image_module.write!(state.image, :memory, suffix: suffix)

        {:ok,
         Entry.new!(
           body: body,
           content_type: mime_type,
           headers: response_headers_for_state(state),
           created_at: DateTime.utc_now()
         )}
      rescue
        exception -> {:error, {:encode, exception, __STACKTRACE__}}
      end
    end
  end

  defp response_headers_for_state(%TransformState{output: :auto}), do: [{"vary", "Accept"}]
  defp response_headers_for_state(%TransformState{}), do: []

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

  defp output_mime_type(%Plug.Conn{} = conn, %TransformState{output: :auto, image: image}) do
    accept_header = conn |> get_req_header("accept") |> Enum.join(",")

    OutputNegotiation.negotiate(accept_header, Image.has_alpha?(image))
  end

  defp output_mime_type(_conn, %TransformState{output: format}) when is_atom(format) do
    {:ok, "image/#{format}"}
  end

  defp send_not_acceptable(%Plug.Conn{} = conn) do
    conn
    |> put_resp_header("vary", "Accept")
    |> put_resp_content_type("text/plain")
    |> send_resp(406, "no acceptable image output format")
  end

  defp send_encode_error(%Plug.Conn{} = conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "error encoding image")
  end
end
