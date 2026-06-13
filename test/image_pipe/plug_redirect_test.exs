defmodule ImagePipe.PlugRedirectTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  defmodule RedirectParser do
    @behaviour ImagePipe.Parser
    @impl true
    def parse(_conn, _opts), do: {:redirect, 303, "/iiif/abc/info.json"}
    @impl true
    def handle_error(conn, _error), do: send_resp(conn, 400, "")
  end

  test "a {:redirect, …} parse result short-circuits to a 303 with Location" do
    conn =
      conn(:get, "/iiif/abc")
      |> ImagePipe.Plug.call(ImagePipe.Plug.init(parser: RedirectParser))

    assert conn.status == 303
    assert get_resp_header(conn, "location") == ["/iiif/abc/info.json"]
  end
end
