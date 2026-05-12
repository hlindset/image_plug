defmodule ImagePlug.Runtime.OriginTest do
  use ExUnit.Case, async: false

  alias ImagePlug.Runtime.Origin

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

  test "fetch exposes a Req-backed stream" do
    plug = fn conn ->
      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: plug)

    assert Enum.join(response.stream) == "image bytes"
    assert response.url == "https://img.example/cat.jpg"
  end

  test "fetch does not allow request options to override safe options" do
    plug = fn conn ->
      Plug.Conn.send_resp(conn, 200, "#{conn.host}#{conn.request_path}")
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

  test "fetch accepts Req timeout overrides" do
    assert_req_async_contract!()
    adapter = streaming_async_adapter()

    assert {:ok, %Origin.Response{} = default_response} =
             Origin.fetch("https://img.example/cat.jpg", adapter: adapter)

    assert Enum.join(default_response.stream) == "image bytes"

    assert {:ok, %Origin.Response{} = override_response} =
             Origin.fetch("https://img.example/cat.jpg",
               adapter: adapter,
               receive_timeout: 123,
               pool_timeout: 234,
               connect_options: [timeout: 345, protocols: [:http1]]
             )

    assert Enum.join(override_response.stream) == "image bytes"
  end

  test "fetch allows redirect limits to be configured" do
    plug = fn
      %{request_path: "/redirect"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/final")
        |> Plug.Conn.send_resp(302, "")

      %{request_path: "/final"} = conn ->
        Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/redirect",
               plug: plug,
               max_redirects: 0
             )

    assert Enum.to_list(response.stream) == []
  end

  test "non-success status produces an empty stream" do
    plug = fn conn ->
      Plug.Conn.send_resp(conn, 404, "not found")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/missing.jpg", plug: plug)

    assert Enum.to_list(response.stream) == []
  end

  test "stream stops when body exceeds limit" do
    plug = fn conn ->
      Plug.Conn.send_resp(conn, 200, "123456")
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.png",
               plug: plug,
               max_body_bytes: 5
             )

    assert Enum.to_list(response.stream) == []
  end

  test "transport errors produce an empty stream" do
    plug = fn conn ->
      Req.Test.transport_error(conn, :timeout)
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", plug: plug)

    assert Enum.to_list(response.stream) == []
  end

  test "stream receive timeout stops the stream" do
    assert_req_async_contract!()

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg",
               adapter: silent_async_adapter(),
               receive_timeout: 10
             )

    assert Enum.to_list(response.stream) == []
  end

  test "stream cleanup cancels the async response" do
    test_pid = self()

    adapter = fn request ->
      ref = make_ref()
      send(self(), {ref, {:data, "image bytes"}})

      async = %Req.Response.Async{
        pid: self(),
        ref: ref,
        stream_fun: &stream_test_message/2,
        cancel_fun: fn canceled_ref -> send(test_pid, {:canceled, canceled_ref}) end
      }

      response = Req.Response.new(status: 200, body: async)

      {request, response}
    end

    assert {:ok, %Origin.Response{} = response} =
             Origin.fetch("https://img.example/cat.jpg", adapter: adapter)

    assert Enum.take(response.stream, 1) == ["image bytes"]
    assert_receive {:canceled, _ref}
  end

  defp streaming_async_adapter do
    fn request ->
      ref = make_ref()
      send(self(), {ref, {:data, "image bytes"}})
      send(self(), {ref, :done})

      async = %Req.Response.Async{
        pid: self(),
        ref: ref,
        stream_fun: &stream_test_message/2,
        cancel_fun: fn _ref -> :ok end
      }

      response = Req.Response.new(status: 200, body: async)

      {request, response}
    end
  end

  defp silent_async_adapter do
    fn request ->
      ref = make_ref()

      async = %Req.Response.Async{
        pid: self(),
        ref: ref,
        stream_fun: &stream_test_message/2,
        cancel_fun: fn _ref -> :ok end
      }

      response = Req.Response.new(status: 200, body: async)

      {request, response}
    end
  end

  defp stream_test_message(ref, {ref, {:data, data}}), do: {:ok, [data: data]}
  defp stream_test_message(ref, {ref, :done}), do: {:ok, [:done]}
  defp stream_test_message(ref, {ref, data}) when is_binary(data), do: {:ok, [data: data]}
  defp stream_test_message(_ref, {:ok, data}) when is_binary(data), do: {:ok, [data: data]}
  defp stream_test_message(_ref, _message), do: :unknown

  defp assert_req_async_contract! do
    required_keys = [:cancel_fun, :pid, :ref, :stream_fun]
    async_keys = Map.keys(%Req.Response.Async{})

    assert required_keys -- async_keys == []
  end
end
