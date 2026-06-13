defmodule ImagePipe.Response.SenderRenderTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.Sender

  test "sends a {:rendered} delivery as a complete body with prepared cache headers" do
    prepared = %CacheHeaders{
      headers: [{"cache-control", "public, max-age=60"}],
      representation_headers: [{"etag", ~s("abc")}],
      etag: ~s("abc")
    }

    conn = conn(:get, "/info/x")

    sent =
      Sender.send_result(
        conn,
        {:ok, {:rendered, "application/json", ~s({"a":1}), [], prepared}},
        []
      )

    assert sent.status == 200
    assert sent.resp_body == ~s({"a":1})
    assert get_resp_header(sent, "content-type") == ["application/json; charset=utf-8"]
    assert get_resp_header(sent, "cache-control") == ["public, max-age=60"]
    assert get_resp_header(sent, "etag") == [~s("abc")]
  end

  test "respects a host-set cache-control instead of overwriting it (same precedence as image responses)" do
    prepared = %CacheHeaders{
      headers: [{"cache-control", "public, max-age=60"}],
      representation_headers: [],
      etag: nil
    }

    conn =
      conn(:get, "/info/x")
      |> put_resp_header("cache-control", "no-store")

    sent =
      Sender.send_result(
        conn,
        {:ok, {:rendered, "application/json", ~s({"a":1}), [], prepared}},
        []
      )

    # The host's stricter cache policy is preserved; the prepared header does not
    # silently relax it (matches the cache-entry/stream delivery paths).
    assert get_resp_header(sent, "cache-control") == ["no-store"]
  end
end
