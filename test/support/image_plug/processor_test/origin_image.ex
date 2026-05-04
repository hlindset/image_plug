defmodule ImagePlug.ProcessorTest.OriginImage do
  @moduledoc false

  def call(%Plug.Conn{request_path: "/images/cat-300.jpg"} = conn, _opts) do
    body = File.read!("priv/static/images/cat-300.jpg")

    conn
    |> Plug.Conn.put_resp_content_type("image/jpeg")
    |> Plug.Conn.send_resp(200, body)
  end

  def call(conn, _opts) do
    Plug.Conn.send_resp(conn, 404, "unexpected origin path")
  end
end
