defmodule ImagePlug.Cache.KeyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Cache.Key
  alias ImagePlug.ProcessingRequest

  defp request(overrides \\ []) do
    struct!(
      ProcessingRequest,
      Keyword.merge(
        [
          signature: "sig-one",
          source_kind: :plain,
          source_path: ["images", "cat.jpg"],
          width: {:pixels, 100},
          height: {:pixels, 80},
          fit: :cover,
          focus: {:anchor, :center, :center},
          format: :webp
        ],
        overrides
      )
    )
  end

  test "builds stable hash and material from canonical request fields and origin identity" do
    conn = conn(:get, "/sig-one/w:100/plain/images/cat.jpg?ignored=true")

    key = Key.build(conn, request(), "https://origin-a.test/images/cat.jpg")
    same = Key.build(conn, request(), "https://origin-a.test/images/cat.jpg")
    different_origin = Key.build(conn, request(), "https://origin-b.test/images/cat.jpg")

    assert key.hash == same.hash
    assert key.hash =~ ~r/\A[0-9a-f]{64}\z/
    assert is_binary(key.serialized_material)
    assert key.material[:schema_version] == 1
    assert key.material[:origin_identity] == "https://origin-a.test/images/cat.jpg"

    assert key.material[:operations] == [
             source_kind: :plain,
             source_path: ["images", "cat.jpg"],
             width: {:pixels, 100},
             height: {:pixels, 80},
             fit: :cover,
             focus: {:anchor, :center, :center}
           ]

    assert key.material[:output] == [format: :webp, accept: nil]
    assert key.material[:selected_headers] == []
    assert key.material[:selected_cookies] == []
    assert key.serialized_material == Key.serialize_material(key.material)
    refute Keyword.has_key?(key.material, :signature)
    refute inspect(key.material) =~ "ignored=true"
    refute key.hash == different_origin.hash
  end

  test "signature changes do not change the key" do
    conn = conn(:get, "/sig-one/plain/images/cat.jpg")
    key_one = Key.build(conn, request(signature: "sig-one"), "https://origin.test/images/cat.jpg")
    key_two = Key.build(conn, request(signature: "sig-two"), "https://origin.test/images/cat.jpg")
    assert key_one.hash == key_two.hash
  end

  test "only configured headers and cookies are included" do
    conn =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept-language", "en-US")
      |> put_req_header("x-ignored", "ignored")
      |> put_req_header("cookie", "tenant=acme; ignored_cookie=ignored")

    key =
      Key.build(conn, request(), "https://origin.test/images/cat.jpg",
        key_headers: ["Accept-Language"],
        key_cookies: ["tenant"]
      )

    assert key.material[:selected_headers] == [{"accept-language", ["en-US"]}]
    assert key.material[:selected_cookies] == [{"tenant", "acme"}]
    refute inspect(key.material) =~ "x-ignored"
    refute inspect(key.material) =~ "ignored_cookie"
  end

  test "format auto includes normalized Accept material" do
    request = request(format: :auto)

    conn_one =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", " Image/WEBP ; Q=0.8 , image/AVIF;q=1 ")

    conn_two =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp;q=0.8,image/avif;q=1")

    key_one = Key.build(conn_one, request, "https://origin.test/images/cat.jpg")
    key_two = Key.build(conn_two, request, "https://origin.test/images/cat.jpg")

    assert key_one.material[:output] == [format: :auto, accept: "image/webp;q=0.8,image/avif;q=1"]
    assert key_one.hash == key_two.hash
  end

  test "missing Accept normalizes to an empty string for format auto" do
    key =
      Key.build(
        conn(:get, "/_/plain/images/cat.jpg"),
        request(format: :auto),
        "https://origin.test/images/cat.jpg"
      )

    assert key.material[:output] == [format: :auto, accept: ""]
  end

  test "wildcard Accept headers normalize whitespace and casing while preserving order" do
    request = request(format: :auto)

    conn_one =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", " image/AVIF , */* ")

    conn_two =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/avif,*/*")

    key_one = Key.build(conn_one, request, "https://origin.test/images/cat.jpg")
    key_two = Key.build(conn_two, request, "https://origin.test/images/cat.jpg")

    assert key_one.material[:output] == [format: :auto, accept: "image/avif,*/*"]
    assert key_one.hash == key_two.hash
  end

  test "format auto drops empty normalized Accept entries" do
    request = request(format: :auto)

    conn_one =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", " , image/AVIF , ")

    conn_two =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/avif")

    key_one = Key.build(conn_one, request, "https://origin.test/images/cat.jpg")
    key_two = Key.build(conn_two, request, "https://origin.test/images/cat.jpg")

    assert key_one.material[:output] == [format: :auto, accept: "image/avif"]
    assert key_one.hash == key_two.hash
  end

  test "format auto preserves media-range order because negotiation may use it as a tiebreaker" do
    request = request(format: :auto)

    conn_one =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/avif,image/webp")

    conn_two =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp,image/avif")

    key_one = Key.build(conn_one, request, "https://origin.test/images/cat.jpg")
    key_two = Key.build(conn_two, request, "https://origin.test/images/cat.jpg")

    refute key_one.hash == key_two.hash
  end

  test "quality values remain key material for format auto" do
    request = request(format: :auto)

    conn_one =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp;q=0.9,image/avif;q=1")

    conn_two =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.9")

    key_one = Key.build(conn_one, request, "https://origin.test/images/cat.jpg")
    key_two = Key.build(conn_two, request, "https://origin.test/images/cat.jpg")

    refute key_one.hash == key_two.hash
  end

  test "explicit formats do not include Accept material" do
    conn =
      :get
      |> conn("/_/format:webp/plain/images/cat.jpg")
      |> put_req_header("accept", "image/jpeg")

    key = Key.build(conn, request(format: :webp), "https://origin.test/images/cat.jpg")

    assert key.material[:output] == [format: :webp, accept: nil]
  end
end
