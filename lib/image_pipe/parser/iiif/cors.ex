defmodule ImagePipe.Parser.IIIF.CORS do
  @moduledoc """
  Mount-level CORS + `OPTIONS` preflight for IIIF endpoints. Mount this AHEAD of
  `ImagePipe.Plug` so `Access-Control-Allow-Origin: *` lands on every IIIF
  response (image, info.json, the 303 redirect, and errors) via a
  `register_before_send/2` hook on the real request conn. The IIIF parser itself
  cannot set these (its `parse/2` returns a tuple, not a conn).
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, OPTIONS")
    |> send_resp(200, "")
    |> halt()
  end

  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      put_resp_header(conn, "access-control-allow-origin", "*")
    end)
  end
end
