defmodule ImagePipe.Response.JsonTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ImagePipe.Response.Json

  test "sends a complete body with the given content type and 200" do
    conn = conn(:get, "/info/x")
    sent = Json.send(conn, "application/json", ~s({"format":"jpeg"}))

    assert sent.status == 200
    assert sent.resp_body == ~s({"format":"jpeg"})
    assert get_resp_header(sent, "content-type") == ["application/json; charset=utf-8"]
    # No image content-disposition is attached.
    assert get_resp_header(sent, "content-disposition") == []
  end

  test "accepts iodata bodies" do
    conn = conn(:get, "/info/x")
    sent = Json.send(conn, "application/json", ["{", ~s("a":1), "}"])
    assert sent.status == 200
    assert sent.resp_body == ~s({"a":1})
  end
end
