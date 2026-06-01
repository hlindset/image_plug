defmodule TwicPicsWireConformanceTest.OriginImage do
  @moduledoc false

  use Boundary, top_level?: true, deps: []

  def init(opts), do: opts

  def call(conn, opts) do
    if pid = opts[:test_pid], do: send(pid, :origin_fetch)
    body = File.read!("priv/static/images/beach.jpg")

    conn
    |> Plug.Conn.put_resp_content_type("image/jpeg")
    |> Plug.Conn.send_resp(200, body)
  end
end
