defmodule ImagePlug do
  @behaviour Plug

  import Plug.Conn

  require Logger

  alias ImagePlug.Origin
  alias ImagePlug.TransformState
  alias ImagePlug.TransformChain

  @type imgp_number() :: integer() | float()
  @type imgp_pixels() :: {:pixels, imgp_number()}
  @type imgp_pct() :: {:percent, imgp_number()}
  @type imgp_scale() :: {:scale, imgp_number(), imgp_number()}
  @type imgp_ratio() :: {imgp_number(), imgp_number()}
  @type imgp_length() :: imgp_pixels() | imgp_pct() | imgp_scale()

  @alpha_format_priority ~w(image/avif image/webp image/png)
  @no_alpha_format_priority ~w(image/avif image/webp image/jpeg)

  def init(opts), do: opts

  def call(%Plug.Conn{} = conn, opts) do
    param_parser = Keyword.fetch!(opts, :param_parser)

    with {:ok, chain} <- param_parser.parse(conn) |> wrap_parser_error(),
         {:ok, origin_response} <- fetch_origin(conn, opts) |> wrap_origin_error(),
         {:ok, image} <-
           Image.from_binary(origin_response.body, access: :random, fail_on: :error)
           |> wrap_decode_error(),
         {:ok, final_state} <- TransformChain.execute(%TransformState{image: image}, chain) do
      send_image(conn, final_state)
    else
      {:error, {:transform_error, %TransformState{errors: errors}}} ->
        Logger.info("transform_error(s): #{inspect(errors)}")
        send_transform_error(conn, errors)

      {:error, {:parser, error}} ->
        param_parser.handle_error(conn, error)

      {:error, {:origin, error}} ->
        send_origin_error(conn, error)

      {:error, {:decode, error}} ->
        send_decode_error(conn, error)
    end
  end

  defp fetch_origin(%Plug.Conn{} = conn, opts) do
    root_url = Keyword.fetch!(opts, :root_url)
    req_options = Keyword.get(opts, :origin_req_options, [])

    with {:ok, url} <- Origin.build_url(root_url, conn.path_info) do
      Origin.fetch(url, req_options)
    end
  end

  defp wrap_parser_error({:error, _} = error), do: {:error, {:parser, error}}
  defp wrap_parser_error(result), do: result

  defp wrap_origin_error({:error, error}), do: {:error, {:origin, error}}
  defp wrap_origin_error(result), do: result

  defp wrap_decode_error({:error, _} = error), do: {:error, {:decode, error}}
  defp wrap_decode_error(result), do: result

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

  defp send_transform_error(%Plug.Conn{} = conn, errors) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(422, "invalid image transform: #{inspect(Enum.reverse(errors))}")
  end

  defp accepted_formats(%Plug.Conn{} = conn) do
    from_accept_header =
      get_req_header(conn, "accept")
      |> Enum.join(",")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&Enum.member?(~w(image/avif image/webp), &1))

    # jpeg and png support is universal
    from_accept_header ++ ~w(image/jpeg image/png)
  end

  defp mime_type_to_suffix("image/avif"), do: ".avif"
  defp mime_type_to_suffix("image/webp"), do: ".webp"
  defp mime_type_to_suffix("image/jpeg"), do: ".jpg"
  defp mime_type_to_suffix("image/png"), do: ".png"

  defp resolve_auto_format(conn, image) do
    all_accepted_formats = accepted_formats(conn)

    format_priority =
      if Image.has_alpha?(image),
        do: @alpha_format_priority,
        else: @no_alpha_format_priority

    Enum.find(format_priority, &Enum.member?(all_accepted_formats, &1))
  end

  defp send_image(%Plug.Conn{} = conn, %TransformState{image: image, output: :blurhash}) do
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

  defp send_image(%Plug.Conn{} = conn, %TransformState{} = state) do
    # figure out which output format to use
    mime_type =
      case state.output do
        :auto -> resolve_auto_format(conn, state.image)
        format when is_atom(format) -> "image/#{format}"
      end

    suffix = mime_type_to_suffix(mime_type)

    conn =
      conn
      |> put_resp_content_type(mime_type, nil)
      |> send_chunked(200)

    stream = Image.stream!(state.image, suffix: suffix)

    Enum.reduce_while(stream, conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end
end
