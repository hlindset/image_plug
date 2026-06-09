defmodule ImagePipeDemoWeb.FiddleImageTest do
  use ImagePipeDemoWeb.ConnCase, async: true

  defp dims(body) do
    {:ok, img} = Image.from_binary(body)
    {Image.width(img), Image.height(img)}
  end

  test "no-geometry request returns the source re-encoded", %{conn: conn} do
    conn = get(conn, "/img/_/plain/images/dog.jpg")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/"
    {w, h} = dims(conn.resp_body)
    assert w == 5011 and h == 7516
  end

  test "crop request returns the cropped dimensions", %{conn: conn} do
    conn = get(conn, "/img/_/c:800:600/plain/images/dog.jpg")
    assert conn.status == 200
    assert {800, 600} == dims(conn.resp_body)
  end
end
