defmodule ImagePlug.Runtime.ResponseSenderTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Plan.Response
  alias ImagePlug.Plan.Response.Filename
  alias ImagePlug.Runtime.ResponseSender

  test "cache hits apply content disposition from plan response" do
    entry = %Entry{
      body: "body",
      content_type: "image/webp",
      headers: [],
      created_at: DateTime.utc_now()
    }

    response = %Response{disposition: :attachment, filename: %Filename{stem: "report"}}

    conn =
      ResponseSender.send_result(conn(:get, "/image"), {:ok, {:cache_entry, entry, response}}, [])

    assert conn.status == 200

    assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="report.webp"; filename*=UTF-8''report.webp)]
  end

  test "image responses apply content disposition on cache misses" do
    {:ok, image} = Image.open("priv/static/images/cat-300.jpg")
    state = %ImagePlug.Transform.State{image: image}

    resolved = %ImagePlug.Output.Resolved{
      format: :webp,
      quality: :default,
      representation_headers: []
    }

    response = %Response{disposition: :inline, filename: %Filename{stem: "miss"}}

    conn =
      ResponseSender.send_result(
        conn(:get, "/image"),
        {:ok, {:image, state, resolved, response}},
        image_module: Image
      )

    assert conn.status == 200

    assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
             [~s(inline; filename="miss.webp"; filename*=UTF-8''miss.webp)]
  end
end
