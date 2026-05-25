defmodule ImagePlug.Response.SenderTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan.Response
  alias ImagePlug.Response.PreparedStream
  alias ImagePlug.Response.Sender

  defmodule ClosingChunkAdapter do
    @behaviour Plug.Conn.Adapter

    @impl Plug.Conn.Adapter
    def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

    @impl Plug.Conn.Adapter
    def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def send_chunked(payload, _status, _headers), do: {:ok, "", %{payload | chunks: 0}}

    @impl Plug.Conn.Adapter
    def chunk(%{chunks: 0} = payload, body) do
      {:ok, IO.iodata_to_binary(body), %{payload | chunks: 1}}
    end

    def chunk(_payload, _body), do: {:error, :closed}

    @impl Plug.Conn.Adapter
    def read_req_body(payload, _opts), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def inform(payload, _status, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def push(payload, _path, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}

    @impl Plug.Conn.Adapter
    def get_http_protocol(_payload), do: :"HTTP/1.1"

    @impl Plug.Conn.Adapter
    def upgrade(payload, _protocol, _opts), do: {:ok, payload}
  end

  defmodule FailingChunkedAdapter do
    @behaviour Plug.Conn.Adapter

    @impl Plug.Conn.Adapter
    def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

    @impl Plug.Conn.Adapter
    def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def send_chunked(_payload, _status, _headers), do: raise("chunked open failed")

    @impl Plug.Conn.Adapter
    def chunk(payload, body), do: {:ok, IO.iodata_to_binary(body), payload}

    @impl Plug.Conn.Adapter
    def read_req_body(payload, _opts), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def inform(payload, _status, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def push(payload, _path, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}

    @impl Plug.Conn.Adapter
    def get_http_protocol(_payload), do: :"HTTP/1.1"

    @impl Plug.Conn.Adapter
    def upgrade(payload, _protocol, _opts), do: {:ok, payload}
  end

  defmodule FirstChunkClosedAdapter do
    @behaviour Plug.Conn.Adapter

    @impl Plug.Conn.Adapter
    def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

    @impl Plug.Conn.Adapter
    def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def send_chunked(payload, _status, _headers), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def chunk(_payload, _body), do: {:error, :closed}

    @impl Plug.Conn.Adapter
    def read_req_body(payload, _opts), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def inform(payload, _status, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def push(payload, _path, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}

    @impl Plug.Conn.Adapter
    def get_http_protocol(_payload), do: :"HTTP/1.1"

    @impl Plug.Conn.Adapter
    def upgrade(payload, _protocol, _opts), do: {:ok, payload}
  end

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

  test "prepared streams send first chunk and pull later chunks" do
    parent = self()
    response = %Response{disposition: :inline, filename: "prepared"}
    next_ref = make_ref()
    replies = start_supervised!({Agent, fn -> [{:chunk, "second"}, :done] end})

    next = fn ->
      send(parent, {next_ref, :next})

      Agent.get_and_update(replies, fn [reply | rest] -> {reply, rest} end)
    end

    prepared =
      prepared_stream(
        first_chunk: "first",
        headers: [{"content-disposition", ~s(inline; filename="prepared.jpg")}],
        next: next
      )

    conn =
      Sender.send_result(conn(:get, "/image"), {:ok, {:prepared_stream, prepared, response}}, [])

    assert conn.status == 200
    assert conn.resp_body == "firstsecond"
    assert_received {^next_ref, :next}
    assert_received {^next_ref, :next}

    assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "image/jpeg")

    assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
             [~s(inline; filename="prepared.jpg")]
  end

  test "prepared streams are not cancelled after normal completion" do
    parent = self()
    cancel_ref = make_ref()
    response = %Response{}

    prepared =
      prepared_stream(
        next: fn -> :done end,
        cancel: fn ->
          send(parent, cancel_ref)
          :ok
        end
      )

    conn =
      Sender.send_result(conn(:get, "/image"), {:ok, {:prepared_stream, prepared, response}}, [])

    assert conn.status == 200
    refute_received ^cancel_ref
  end

  test "prepared streams cancel when next returns an error" do
    parent = self()
    cancel_ref = make_ref()
    response = %Response{}

    attach_telemetry([[:image_plug, :encode, :stop]])

    prepared =
      prepared_stream(
        next: fn -> {:error, {:encode, :failed_after_first_chunk}} end,
        cancel: fn ->
          send(parent, cancel_ref)
          :ok
        end
      )

    conn =
      Sender.send_result(conn(:get, "/image"), {:ok, {:prepared_stream, prepared, response}}, [])

    assert conn.status == 200
    assert conn.private.image_plug_send_result == :processing_error
    assert_receive ^cancel_ref

    assert_receive {:telemetry_event, [:image_plug, :encode, :stop], _measurements,
                    %{
                      result: :processing_error,
                      stream_phase: :encode,
                      error: :encode,
                      status: 200,
                      output_format: :jpeg
                    }}
  end

  test "prepared streams cancel when client closes during later chunk" do
    parent = self()
    cancel_ref = make_ref()

    attach_telemetry([[:image_plug, :encode, :stop]])

    prepared =
      prepared_stream(
        next: fn -> {:chunk, "second"} end,
        cancel: fn ->
          send(parent, cancel_ref)
          :ok
        end
      )

    conn =
      :get
      |> conn("/image")
      |> Map.put(:adapter, {ClosingChunkAdapter, %{chunks: nil}})
      |> Sender.send_result({:ok, {:prepared_stream, prepared, %Response{}}}, [])

    refute Map.has_key?(conn.private, :image_plug_send_result)
    assert conn.resp_body == "first"
    assert_receive ^cancel_ref

    assert_receive {:telemetry_event, [:image_plug, :encode, :stop], _measurements,
                    %{
                      result: :client_closed,
                      stream_phase: :client,
                      error: :client_closed,
                      status: 200,
                      output_format: :jpeg
                    }}
  end

  test "prepared streams cancel when send_chunked fails" do
    parent = self()
    cancel_ref = make_ref()

    attach_telemetry([[:image_plug, :encode, :stop]])

    prepared =
      prepared_stream(
        cancel: fn ->
          send(parent, cancel_ref)
          :ok
        end
      )

    conn =
      :get
      |> conn("/image")
      |> Map.put(:adapter, {FailingChunkedAdapter, %{}})
      |> Sender.send_result({:ok, {:prepared_stream, prepared, %Response{}}}, [])

    assert conn.private.image_plug_send_result == :processing_error
    assert_receive ^cancel_ref

    assert_receive {:telemetry_event, [:image_plug, :encode, :stop], _measurements,
                    %{
                      result: :processing_error,
                      stream_phase: :encode,
                      error: :encode,
                      status: 200,
                      output_format: :jpeg
                    }}
  end

  test "prepared streams cancel when first chunk fails" do
    parent = self()
    cancel_ref = make_ref()

    prepared =
      prepared_stream(
        cancel: fn ->
          send(parent, cancel_ref)
          :ok
        end
      )

    conn =
      :get
      |> conn("/image")
      |> Map.put(:adapter, {FirstChunkClosedAdapter, %{}})
      |> Sender.send_result({:ok, {:prepared_stream, prepared, %Response{}}}, [])

    refute Map.has_key?(conn.private, :image_plug_send_result)
    assert_receive ^cancel_ref
  end

  test "prepared streams cancel when the next callback exits" do
    parent = self()
    cancel_ref = make_ref()

    prepared =
      prepared_stream(
        next: fn -> exit(:session_down) end,
        cancel: fn ->
          send(parent, cancel_ref)
          :ok
        end
      )

    conn =
      Sender.send_result(
        conn(:get, "/image"),
        {:ok, {:prepared_stream, prepared, %Response{}}},
        []
      )

    assert conn.private.image_plug_send_result == :processing_error
    assert_receive ^cancel_ref
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp prepared_stream(overrides) do
    struct!(
      PreparedStream,
      Keyword.merge(
        [
          first_chunk: "first",
          content_type: "image/jpeg",
          headers: [],
          next: fn -> :done end,
          cancel: fn -> :ok end,
          resolved_output: %Resolved{format: :jpeg, quality: :default, response_headers: []}
        ],
        overrides
      )
    )
  end

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
