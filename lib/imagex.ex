defmodule Imagex do
  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Imagex.TransformState
  alias Imagex.TransformChain

  def init(opts), do: opts

  def call(conn, opts) do
    root_url = Keyword.fetch!(opts, :root_url)
    conn = fetch_query_params(conn)
    path = Enum.join(conn.path_info, "/")
    url = "#{root_url}/#{path}"
    image_resp = Req.get!(url)

    with {:ok, image} <- Image.from_binary(image_resp.body),
         {:ok, initial_state} <- {:ok, %TransformState{image: image}},
         {:ok, chain} <- params_to_chain(conn.params),
         {:ok, %TransformState{image: image}} <- TransformChain.execute(initial_state, chain) do
      send_image(conn, image)
    else
      {:error, {:transform_error, %TransformState{errors: errors, image: image}}} ->
        # TODO: handle transform error - debug mode + graceful mode switch?
        Logger.info("transform_error(s): #{inspect(errors)}")
        send_image(conn, image)
    end
  end

  defp params_to_chain(%{"transform" => chain}), do: TransformChain.parse(chain)
  defp params_to_chain(_params), do: {:ok, []}

  defp send_image(conn, image) do
    conn = send_chunked(conn, 200)
    # todo: set correct suffix
    stream = Image.stream!(image, suffix: ".jpg")

    Enum.reduce_while(stream, conn, fn data, conn ->
      case chunk(conn, data) do
        {:ok, conn} -> {:cont, conn}
        {:error, :closed} -> {:halt, conn}
      end
    end)
  end
end
