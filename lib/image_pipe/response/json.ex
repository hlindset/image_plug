defmodule ImagePipe.Response.Json do
  @moduledoc """
  Sends a complete-body, non-image response (content-type + iodata). Used by
  request-layer renders. Does NOT attach image `content-disposition`.
  """

  import Plug.Conn, only: [put_resp_content_type: 2, send_resp: 3]

  @spec send(Plug.Conn.t(), String.t(), iodata()) :: Plug.Conn.t()
  def send(%Plug.Conn{} = conn, content_type, body) do
    conn
    |> put_resp_content_type(content_type)
    |> send_resp(200, body)
  end
end
