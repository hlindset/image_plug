defmodule ImagePlug.SimpleServerTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [get_resp_header: 2]
  import Plug.Test

  test "returns 404 for missing static image origins" do
    conn =
      :get
      |> conn("/images/does-not-exist.jpg")
      |> ImagePlug.SimpleServer.call([])

    assert conn.status == 404
    assert conn.resp_body == "404 Not Found"
  end

  test "serves the demo fiddle shell" do
    conn =
      :get
      |> conn("/demo")
      |> ImagePlug.SimpleServer.call([])

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert conn.resp_body =~ "ImagePlug Fiddle"
    assert conn.resp_body =~ ~s(data-number-for="width")
    assert conn.resp_body =~ ~s(data-number-for="height")
    assert conn.resp_body =~ ~r/data-option="width"[^>]+step="1"/
    assert conn.resp_body =~ ~r/data-option="height"[^>]+step="1"/
  end

  test "serves demo fiddle assets" do
    js_conn =
      :get
      |> conn("/demo/app.js")
      |> ImagePlug.SimpleServer.call([])

    css_conn =
      :get
      |> conn("/demo/styles.css")
      |> ImagePlug.SimpleServer.call([])

    assert js_conn.status == 200
    assert get_resp_header(js_conn, "content-type") == ["text/javascript"]
    assert js_conn.resp_body =~ "buildProcessingPath"
    assert js_conn.resp_body =~ "syncNumberInput"

    assert css_conn.status == 200
    assert get_resp_header(css_conn, "content-type") == ["text/css"]
    assert css_conn.resp_body =~ "fiddle-shell"
  end
end
