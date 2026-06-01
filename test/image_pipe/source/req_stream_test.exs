defmodule ImagePipe.Source.ReqStreamTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.ReqStream
  alias ImagePipe.Source.StreamError

  test "runs validate_target before connecting and raises the denial reason" do
    plug = fn _conn -> flunk("must not connect when target is denied") end

    stream =
      ReqStream.stream(
        [url: "https://blocked.example/x", plug: plug],
        validate_target: fn _url -> {:error, :denied_address} end
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :denied_address
  end

  test "follows a redirect itself and validates the hop target" do
    plug = fn
      %{request_path: "/redirect.jpg"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://hop.example/other.jpg")
        |> Plug.Conn.send_resp(302, "")

      conn ->
        send(self(), {:got, conn.host, conn.request_path})
        Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    seen = self()

    stream =
      ReqStream.stream(
        [url: "https://assets.example.com/redirect.jpg", plug: plug],
        validate_target: fn url ->
          send(seen, {:validated, url})
          :ok
        end,
        max_redirects: 1
      )

    assert Enum.join(stream) == "image bytes"
    assert_received {:validated, "https://assets.example.com/redirect.jpg"}
    assert_received {:validated, "https://hop.example/other.jpg"}
    assert_received {:got, "hop.example", "/other.jpg"}
  end

  test "denies a redirect hop before connecting to it" do
    plug = fn
      %{request_path: "/redirect.jpg"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://internal.example/x")
        |> Plug.Conn.send_resp(302, "")

      %{host: "internal.example"} ->
        flunk("must not connect to denied hop")

      conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
    end

    stream =
      ReqStream.stream(
        [url: "https://assets.example.com/redirect.jpg", plug: plug],
        validate_target: fn
          "https://internal.example/x" -> {:error, :denied_host}
          _ -> :ok
        end,
        max_redirects: 3
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :denied_host
  end

  test "exhausting max_redirects fails with too_many_redirects" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://assets.example.com/loop")
      |> Plug.Conn.send_resp(302, "")
    end

    stream =
      ReqStream.stream(
        [url: "https://assets.example.com/loop", plug: plug],
        validate_target: fn _ -> :ok end,
        max_redirects: 1
      )

    error = assert_raise StreamError, fn -> Enum.to_list(stream) end
    assert error.reason == :too_many_redirects
  end
end
