defmodule ImagePlug.ImagePlugTest do
  use ExUnit.Case, async: true
  use Plug.Test

  doctest ImagePlug

  defmodule OriginShouldNotBeCalled do
    def call(conn) do
      send(self(), :origin_was_called)
      Plug.Conn.send_resp(conn, 200, "unexpected")
    end
  end

  test "does not fetch origin when transform params are invalid" do
    conn =
      conn(
        :get,
        "/process/images/cat-300.jpg?twic=v1/resize=-x-"
      )

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Twicpics,
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    assert conn.status == 400
    refute_received :origin_was_called
  end
end
