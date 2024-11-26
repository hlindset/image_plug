defmodule PlugImage do
  @behaviour Plug

  import Plug.Conn

  require Logger

  alias PlugImage.TransformState
  alias PlugImage.TransformChain

  def init(opts), do: opts

  def call(%Plug.Conn{} = conn, opts) do
    root_url = Keyword.fetch!(opts, :root_url)
    param_parser = Keyword.fetch!(opts, :param_parser)
    path = Enum.join(conn.path_info, "/")
    url = "#{root_url}/#{path}"
    image_resp = Req.get!(url)

    with {:ok, chain} <- param_parser.parse(conn),
         {:ok, image} <- Image.from_binary(image_resp.body),
         {:ok, final_state} <- TransformChain.execute(%TransformState{image: image}, chain) do
      send_image(conn, final_state)
    else
      {:error, {:transform_error, %TransformState{errors: errors} = final_state}} ->
        # TODO: handle transform error - debug mode + graceful mode switch?
        Logger.info("transform_error(s): #{inspect(errors)}")
        send_image(conn, final_state)
    end
  end

  @alpha_format_priority ~w(image/avif image/webp image/png)
  @no_alpha_format_priority ~w(image/avif image/webp image/jpeg)

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
