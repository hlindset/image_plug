defmodule ImagePipeFiddleWeb.IIIF do
  @moduledoc """
  Forwards /iiif-image requests to ImagePipe.Plug with opts built at boot.

  Composes ImagePipe.Parser.IIIF.CORS ahead of ImagePipe.Plug so OPTIONS
  preflight is answered and `Access-Control-Allow-Origin: *` lands on every
  response. Interim manual composition — #284 moves CORS behind a Parser hook,
  after which this plug delegates straight to ImagePipe.Plug.
  """
  @behaviour Plug

  alias ImagePipe.Parser.IIIF.CORS

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    cors_conn = CORS.call(conn, CORS.init([]))

    if cors_conn.halted do
      cors_conn
    else
      ImagePipe.Plug.call(
        cors_conn,
        :persistent_term.get({ImagePipeFiddle.Application, :iiif_opts})
      )
    end
  end
end
