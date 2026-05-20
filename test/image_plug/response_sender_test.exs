defmodule ImagePlug.Response.SenderTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Plan.Response
  alias ImagePlug.Response.Sender

  test "cache hits apply content disposition from plan response" do
    entry = %Entry{
      body: "body",
      content_type: "image/webp",
      headers: [],
      created_at: DateTime.utc_now()
    }

    response = %Response{disposition: :attachment, filename: "report"}

    conn =
      Sender.send_result(conn(:get, "/image"), {:ok, {:cache_entry, entry, response}}, [])

    assert conn.status == 200

    assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="report.webp")]
  end

  test "image responses apply content disposition on cache misses" do
    {:ok, image} = Image.open("priv/static/images/beach.jpg")
    state = %ImagePlug.Transform.State{image: image}

    resolved = %ImagePlug.Output.Resolved{
      format: :webp,
      quality: :default,
      response_headers: []
    }

    response = %Response{disposition: :inline, filename: "miss"}

    conn =
      Sender.send_result(
        conn(:get, "/image"),
        {:ok, {:image, state, resolved, response}},
        image_module: Image
      )

    assert conn.status == 200

    assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
             [~s(inline; filename="miss.webp")]
  end
end
