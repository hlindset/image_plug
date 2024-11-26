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
         {:ok, initial_state} <- {:ok, %TransformState{image: image}},
         {:ok, %TransformState{image: image}} <- TransformChain.execute(initial_state, chain) do
      send_image(conn, image)
    else
      {:error, {:transform_error, %TransformState{errors: errors, image: image}}} ->
        # TODO: handle transform error - debug mode + graceful mode switch?
        Logger.info("transform_error(s): #{inspect(errors)}")
        send_image(conn, image)
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

    from_accept_header ++ ~w(image/jpeg image/png)
  end

  defp mime_type_to_suffix("image/avif"), do: ".avif"
  defp mime_type_to_suffix("image/webp"), do: ".webp"
  defp mime_type_to_suffix("image/jpeg"), do: ".jpg"
  defp mime_type_to_suffix("image/png"), do: ".png"

  defp resolve_suffix(conn, image) do
    all_accepted_formats = accepted_formats(conn)

    format_priority =
      if Image.has_alpha?(image), do: @alpha_format_priority, else: @no_alpha_format_priority

    mime_type = Enum.find(format_priority, &Enum.member?(all_accepted_formats, &1))
    {mime_type, mime_type_to_suffix(mime_type)}
  end

  defp send_image(conn, image) do
    # figure out which format to use
    {mime_type, suffix} = resolve_suffix(conn, image)

    conn =
      conn
      |> put_resp_content_type(mime_type, nil)
      |> send_chunked(200)

    stream = Image.stream!(image, suffix: suffix)

    Enum.reduce_while(stream, conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end
end
