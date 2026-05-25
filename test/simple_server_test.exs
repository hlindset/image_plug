defmodule ImagePipe.SimpleServerTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [get_resp_header: 2]
  import Plug.Test

  test "returns 404 for missing static images" do
    conn =
      :get
      |> conn("/images/does-not-exist.jpg")
      |> ImagePipe.SimpleServer.call([])

    assert conn.status == 404
    assert conn.resp_body == "404 Not Found"
  end

  test "processes native-style local source URLs through configured file source" do
    conn =
      :get
      |> conn("/_/plain/local:///images/dog.jpg")
      |> ImagePipe.SimpleServer.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert byte_size(conn.resp_body) > 0
  end

  test "serves the demo fiddle shell" do
    conn =
      :get
      |> conn("/demo")
      |> ImagePipe.SimpleServer.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert conn.resp_body =~ "ImagePipe Fiddle"
    assert conn.resp_body =~ ~s(src="http://localhost:5173/@vite/client")
    assert conn.resp_body =~ ~s(src="http://localhost:5173/demo/src/main.ts")
    refute conn.resp_body =~ "/demo/assets/"
  end

  test "serves the demo fiddle shell for shareable demo paths" do
    conn =
      :get
      |> conn("/demo/rs:fill:640:360:0/g:ce/f:jpeg/q:85/plain/local:///images/dog.jpg")
      |> ImagePipe.SimpleServer.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert conn.resp_body =~ "ImagePipe Fiddle"
    assert conn.resp_body =~ ~s(src="http://localhost:5173/demo/src/main.ts")
  end
end
