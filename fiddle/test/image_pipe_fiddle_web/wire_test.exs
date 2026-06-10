defmodule ImagePipeFiddleWeb.WireTest do
  use ImagePipeFiddleWeb.ConnCase, async: true

  test "GET / serves the SPA shell", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end

  test "deep-link path also serves the shell", %{conn: conn} do
    conn = get(conn, "/rs:fill:640:360/plain/local:///images/dog.jpg")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end

  test "GET /images/:file serves a raw static image", %{conn: conn} do
    conn = get(conn, "/images/dog.jpg")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/"
  end

  test "GET /img processes an unsigned request", %{conn: conn} do
    conn = get(conn, "/img/_/rs:fill:200:200/plain/local:///images/dog.jpg")
    assert conn.status == 200
    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    assert Image.width(image) == 200
    assert Image.height(image) == 200
  end

  test "GET /img verifies a real HMAC-signed path under the mount", %{conn: conn} do
    signed_path = "/rs:fill:200:200/plain/local:///images/dog.jpg"
    signature = sign(signed_path, "736563726574", "68656c6c6f")
    conn = get(conn, "/img/#{signature}#{signed_path}")
    assert conn.status == 200
  end

  defp sign(signed_path, key_hex, salt_hex) do
    key = Base.decode16!(key_hex, case: :lower)
    salt = Base.decode16!(salt_hex, case: :lower)

    :crypto.mac(:hmac, :sha256, key, salt <> signed_path)
    |> binary_part(0, 32)
    |> Base.url_encode64(padding: false)
  end
end
