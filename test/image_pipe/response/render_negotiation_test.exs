defmodule ImagePipe.Response.RenderNegotiationTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.Sender

  @offers [
    {"application/ld+json;profile=\"http://iiif.io/api/image/3/context.json\"",
     ["application/ld+json"]}
  ]

  @bare_cache_headers %CacheHeaders{headers: [], representation_headers: [], etag: nil}

  defp render(accept) do
    delivery = {:ok, {:rendered, "application/json", "{}", @offers, @bare_cache_headers}}
    conn(:get, "/") |> put_req_header("accept", accept) |> Sender.send_result(delivery, [])
  end

  test "upgrades Content-Type to ld+json when Accept allows it, with Vary: Accept" do
    conn = render("application/ld+json")
    assert ["application/ld+json;" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "falls back to application/json otherwise, still Vary: Accept" do
    conn = render("application/json")
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "no offers (imgproxy /info path): content-type unchanged, no Vary" do
    delivery = {:ok, {:rendered, "application/json", "{}", [], @bare_cache_headers}}
    conn = conn(:get, "/") |> Sender.send_result(delivery, [])
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "vary") == []
  end

  test "offers present but no Accept header: base type + Vary: Accept" do
    delivery = {:ok, {:rendered, "application/json", "{}", @offers, @bare_cache_headers}}
    conn = conn(:get, "/") |> Sender.send_result(delivery, [])
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    assert get_resp_header(conn, "vary") == ["Accept"]
  end
end
