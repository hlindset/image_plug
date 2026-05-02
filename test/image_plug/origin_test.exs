defmodule ImagePlug.OriginTest do
  use ExUnit.Case, async: false

  alias ImagePlug.Origin
  alias ImagePlug.Origin.StreamStatus

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
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: plug)

    assert Enum.join(response.stream) == "image bytes"
    assert Origin.stream_status(response) == :done
    assert response.content_type == "image/jpeg"
    assert response.url == "https://img.example/cat.jpg"
    assert {"content-type", "image/jpeg"} in response.headers
  end

  test "stream_status reports done idempotently after stream completion" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: plug)

    assert Origin.stream_status(response) == :pending
    assert Enum.join(response.stream) == "image bytes"
    assert Origin.stream_status(response) == :done
    assert Origin.stream_status(response) == :done
  end

  test "stream_status is visible from another process after stream completion" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: plug)

    assert Enum.join(response.stream) == "image bytes"

    test_pid = self()
    spawn(fn -> send(test_pid, {:stream_status, Origin.stream_status(response)}) end)

    assert_receive {:stream_status, :done}
  end

  test "stream_status reports stream errors idempotently" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.send_resp(200, "123456")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.png",
               plug: plug,
               max_body_bytes: 5
             )

    assert Enum.to_list(response.stream) == []
    assert Origin.stream_status(response) == {:error, {:body_too_large, 5}}
    assert Origin.stream_status(response) == {:error, {:body_too_large, 5}}
  end

  test "stream status holder only records terminal statuses" do
    assert {:ok, stream_status} = StreamStatus.start_link()

    assert StreamStatus.put(stream_status, :bogus) == :pending
    assert StreamStatus.get(stream_status) == :pending
    assert StreamStatus.put(stream_status, :done) == :done
    assert StreamStatus.put(stream_status, {:error, :late_error}) == :done

    StreamStatus.stop(stream_status)
  end

  test "require_stream_status fails pending streams before delivery" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: plug)

    assert Origin.stream_status(response) == :pending

    assert Origin.require_stream_status(response) ==
             {:error, :stream_not_finished_after_materialization}

    assert Origin.stream_status(response) == {:error, :stream_not_finished_after_materialization}

    assert Origin.require_stream_status(response) ==
             {:error, :stream_not_finished_after_materialization}
  end

  test "stream_status remains readable after close cancels an unconsumed stream" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: plug)

    assert Origin.stream_status(response) == :pending
    assert Origin.close(response) == :ok
    assert Origin.stream_status(response) == :pending
    assert Origin.stream_status(response) == :pending
  end

  test "stream_status holder exits when the fetch owner exits normally" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end

    test_pid = self()

    owner =
      spawn(fn ->
        case Origin.fetch("https://img.example/cat.jpg", plug: plug) do
          {:ok, %Origin.Response{} = response} ->
            send(test_pid, {:stream_status_holder, response.stream_status})

          other ->
            send(test_pid, {:fetch_result, other})
        end
      end)

    owner_ref = Process.monitor(owner)

    assert_receive {:stream_status_holder, stream_status}, 1_000
    stream_status_ref = Process.monitor(stream_status)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}, 1_000
    assert_receive {:DOWN, ^stream_status_ref, :process, ^stream_status, _reason}, 1_000
  end

  test "fetch accepts mixed-case image content type with parameters" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "Image/JPEG; charset=binary")
      |> Plug.Conn.send_resp(200, "image bytes")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: plug)

    assert response.content_type == "Image/JPEG; charset=binary"
  end

  test "fetch does not allow request options to override safe options" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "#{conn.host}#{conn.request_path}")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg",
               plug: plug,
               url: "https://evil.example/dog.jpg",
               into: [],
               receive_timeout: 5_000,
               max_redirects: 0
             )

    assert Enum.join(response.stream) == "img.example/cat.jpg"
    assert response.url == "https://img.example/cat.jpg"
  end

  test "fetch allows redirect limits to be configured" do
    plug = fn
      %{request_path: "/redirect"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/final")
        |> Plug.Conn.send_resp(302, "")

      %{request_path: "/final"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
        |> Plug.Conn.send_resp(200, "image bytes")
    end

    assert {:error, {:transport, %Req.TooManyRedirectsError{max_redirects: 0}}} =
             Origin.fetch("https://img.example/redirect",
               plug: plug,
               max_redirects: 0
             )
  end

  test "rejects non-success status" do
    plug = fn conn ->
      Plug.Conn.send_resp(conn, 404, "not found")
    end

    assert Origin.fetch("https://img.example/missing.jpg", plug: plug) ==
             {:error, {:bad_status, 404}}
  end

  test "rejects non-image content type" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/plain; charset=utf-8")
      |> Plug.Conn.send_resp(200, "not image bytes")
    end

    assert Origin.fetch("https://img.example/cat.txt", plug: plug) ==
             {:error, {:bad_content_type, "text/plain; charset=utf-8"}}
  end

  test "stream stops reading and records an origin error when body exceeds limit" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/png")
      |> Plug.Conn.send_resp(200, "123456")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.png",
               plug: plug,
               max_body_bytes: 5
             )

    assert Enum.to_list(response.stream) == []
    assert Origin.stream_status(response) == {:error, {:body_too_large, 5}}
  end

  test "converts transport errors" do
    plug = fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end

    assert {:error, {:transport, %Req.TransportError{reason: :timeout}}} =
             Origin.fetch("https://img.example/cat.jpg", plug: plug)
  end

  test "stream receive timeout is recorded as an origin error" do
    ref = make_ref()
    {port, server} = start_slow_chunked_origin(self(), ref)
    monitor_ref = Process.monitor(server)

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("http://127.0.0.1:#{port}/cat.png", receive_timeout: 300)

    assert_receive {^ref, :first_chunk_sent, ^server}
    assert Enum.to_list(response.stream) == ["first chunk"]
    assert Origin.stream_status(response) == {:error, {:timeout, 300}}

    send(server, {ref, :close})
    assert_receive {:DOWN, ^monitor_ref, :process, ^server, _reason}
  end

  test "unconsumed streams are canceled after receive timeout" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg",
               plug: plug,
               receive_timeout: 100
             )

    worker = response.worker
    monitor_ref = Process.monitor(worker)

    assert_receive {:DOWN, ^monitor_ref, :process, ^worker, _reason}, 500
    assert Origin.stream_status(response) == {:error, {:timeout, 100}}
  end

  test "close cancels an unconsumed stream" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "image/jpeg")
      |> Plug.Conn.send_resp(200, "image bytes")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: plug)

    worker = response.worker
    monitor_ref = Process.monitor(worker)

    assert Origin.close(response) == :ok
    assert_receive {:DOWN, ^monitor_ref, :process, ^worker, _reason}
  end

  defp start_slow_chunked_origin(test_pid, ref) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)

    server =
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

        send(test_pid, {ref, :first_chunk_sent, self()})
        await_slow_chunked_origin_close(ref, socket, listen_socket)
      end)

    {port, server}
  end

  defp await_slow_chunked_origin_close(ref, socket, listen_socket) do
    receive do
      {^ref, :send_second_chunk} ->
        :gen_tcp.send(socket, "c\r\nsecond chunk\r\n0\r\n\r\n")
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)

      {^ref, :close} ->
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
    after
      5_000 ->
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
    end
  end
end
