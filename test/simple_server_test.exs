defmodule ImagePlug.SimpleServerTest do
  use ExUnit.Case, async: true

  import Plug.Test

  test "returns 404 for missing static image origins" do
    conn =
      :get
      |> conn("/images/does-not-exist.jpg")
      |> ImagePlug.SimpleServer.call([])

    assert conn.status == 404
    assert conn.resp_body == "404 Not Found"
  end
end
