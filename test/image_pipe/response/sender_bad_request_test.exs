defmodule ImagePipe.Response.SenderBadRequestTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Response.Sender

  test "a {:bad_request, _} transform error sends 400" do
    result = {:error, {:processing, {:transform_error, {:bad_request, :upscale_required}}, []}}
    conn = Sender.send_result(conn(:get, "/"), result, [])
    assert conn.status == 400
  end

  test "any other transform error still sends 422" do
    result = {:error, {:processing, {:transform_error, {:some_op, :boom}}, []}}
    conn = Sender.send_result(conn(:get, "/"), result, [])
    assert conn.status == 422
  end
end
