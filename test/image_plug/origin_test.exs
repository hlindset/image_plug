defmodule ImagePlug.OriginTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Origin

  setup do
    Req.Test.verify_on_exit!()
  end

  test "build_url encodes and joins path segments" do
    assert Origin.build_url("https://img.example/base", ["images", "cat 1.jpg"]) ==
             {:ok, "https://img.example/base/images/cat%201.jpg"}
  end

  test "build_url rejects dot segments before joining paths" do
    assert Origin.build_url("https://img.example/base", ["..", "secret.jpg"]) ==
             {:error, {:invalid_path_segment, ["..", "secret.jpg"]}}

    assert Origin.build_url("https://img.example/base", ["images", ".", "cat.jpg"]) ==
             {:error, {:invalid_path_segment, ["images", ".", "cat.jpg"]}}
  end

  test "fetch validates status and image content type and exposes a guarded stream" do
    Req.Test.stub(Origin, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end)

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: {Req.Test, Origin})

    assert Enum.join(response.stream) == "image bytes"
    assert Origin.stream_error(response) == nil
    assert response.content_type == "image/jpeg"
    assert response.url == "https://img.example/cat.jpg"
    assert {"content-type", "image/jpeg"} in response.headers
  end

  test "fetch accepts mixed-case image content type with parameters" do
    Req.Test.stub(Origin, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "Image/JPEG; charset=binary")
      |> Plug.Conn.send_resp(200, "image bytes")
    end)

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: {Req.Test, Origin})

    assert response.content_type == "Image/JPEG; charset=binary"
  end

  test "fetch does not allow request options to override safe options" do
    Req.Test.stub(Origin, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "#{conn.host}#{conn.request_path}")
    end)

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg",
               plug: {Req.Test, Origin},
               url: "https://evil.example/dog.jpg",
               into: [],
               receive_timeout: 5_000,
               max_redirects: 0
             )

    assert Enum.join(response.stream) == "img.example/cat.jpg"
    assert response.url == "https://img.example/cat.jpg"
  end

  test "fetch allows redirect limits to be configured" do
    Req.Test.stub(Origin, fn
      %{request_path: "/redirect"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/final")
        |> Plug.Conn.send_resp(302, "")

      %{request_path: "/final"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
        |> Plug.Conn.send_resp(200, "image bytes")
    end)

    assert {:error, {:transport, %Req.TooManyRedirectsError{max_redirects: 0}}} =
             Origin.fetch("https://img.example/redirect",
               plug: {Req.Test, Origin},
               max_redirects: 0
             )
  end

  test "rejects non-success status" do
    Req.Test.stub(Origin, fn conn ->
      Plug.Conn.send_resp(conn, 404, "not found")
    end)

    assert Origin.fetch("https://img.example/missing.jpg", plug: {Req.Test, Origin}) ==
             {:error, {:bad_status, 404}}
  end

  test "rejects non-image content type" do
    Req.Test.stub(Origin, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain; charset=utf-8")
      |> Plug.Conn.send_resp(200, "not image bytes")
    end)

    assert Origin.fetch("https://img.example/cat.txt", plug: {Req.Test, Origin}) ==
             {:error, {:bad_content_type, "text/plain; charset=utf-8"}}
  end

  test "stream stops reading and records an origin error when body exceeds limit" do
    Req.Test.stub(Origin, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.send_resp(200, "123456")
    end)

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.png",
               plug: {Req.Test, Origin},
               max_body_bytes: 5
             )

    assert Enum.to_list(response.stream) == []
    assert Origin.stream_error(response) == {:body_too_large, 5}
  end

  test "converts transport errors" do
    Req.Test.stub(Origin, fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, {:transport, %Req.TransportError{reason: :timeout}}} =
             Origin.fetch("https://img.example/cat.jpg", plug: {Req.Test, Origin})
  end

  test "stream receive timeout is recorded as an origin error" do
    port = start_slow_chunked_origin()

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("http://127.0.0.1:#{port}/cat.png", receive_timeout: 100)

    assert Enum.to_list(response.stream) == ["first chunk"]
    assert Origin.stream_error(response) == {:timeout, 100}
  end

  test "unconsumed streams are canceled after receive timeout" do
    Req.Test.stub(Origin, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end)

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg",
               plug: {Req.Test, Origin},
               receive_timeout: 50
             )

    ref = response.ref
    assert_receive {^ref, {:stream_error, {:timeout, 50}}}, 100
  end

  test "close cancels an unconsumed stream" do
    Req.Test.stub(Origin, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end)

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: {Req.Test, Origin})

    worker = response.worker
    monitor_ref = Process.monitor(worker)

    assert Origin.close(response) == :ok
    assert_receive {:DOWN, ^monitor_ref, :process, ^worker, _reason}
  end

  defp start_slow_chunked_origin do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen_socket)
      {:ok, _request} = :gen_tcp.recv(socket, 0)

      :ok =
        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\n",
          "content-type: image/png\r\n",
          "transfer-encoding: chunked\r\n",
          "\r\n",
          "b\r\nfirst chunk\r\n"
        ])

      Process.sleep(150)
      :gen_tcp.send(socket, "c\r\nsecond chunk\r\n0\r\n\r\n")
      :gen_tcp.close(socket)
      :gen_tcp.close(listen_socket)
    end)

    port
  end
end
