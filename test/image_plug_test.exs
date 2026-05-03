defmodule ImagePlug.ImagePlugTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  doctest ImagePlug

  alias ImagePlug.ProcessingRequest

  defmodule CacheProbe do
    alias ImagePlug.Cache.Entry
    alias ImagePlug.Cache.Key

    def get(%Key{} = key, opts) do
      opts
      |> Keyword.get(:message_target, self())
      |> send({:cache_get, key})

      case Keyword.fetch(opts, :get_result_fun) do
        {:ok, get_result_fun} -> get_result_fun.(key)
        :error -> Keyword.get(opts, :get_result, :miss)
      end
    end

    def put(%Key{} = key, %Entry{} = entry, opts) do
      opts
      |> Keyword.get(:message_target, self())
      |> send({:cache_put, key, entry})

      Keyword.get(opts, :put_result, :ok)
    end
  end

  defmodule OriginShouldNotBeCalled do
    def call(conn, _opts) do
      send(self(), :origin_was_called)
      Plug.Conn.send_resp(conn, 200, "unexpected")
    end
  end

  defmodule OriginImage do
    def call(conn, _) do
      body = File.read!("priv/static/images/cat-300.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule CountingOriginImage do
    def init(opts), do: opts

    def call(conn, opts) do
      test_pid = Keyword.get(opts, :test_pid) || conn.owner || self()
      Kernel.send(test_pid, :origin_was_called)

      body = File.read!("priv/static/images/cat-300.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule StreamingOnlyImage do
    def stream!(_image, suffix: ".jpg") do
      send(self(), :stream_encoder_called)
      ["streamed jpeg"]
    end

    def write!(_image, :memory, suffix: ".jpg") do
      send(self(), :memory_encoder_called)
      raise "cache-enabled memory encoder should not be called"
    end
  end

  defmodule MultiChunkStreamingImage do
    def stream!(_image, suffix: ".jpg") do
      send(self(), :stream_encoder_called)
      ["first chunk", "second chunk"]
    end
  end

  defmodule EmptyStreamingImage do
    def stream!(_image, suffix: ".jpg") do
      send(self(), :stream_encoder_called)
      []
    end
  end

  defmodule ClosedChunkAdapter do
    def send_chunked(%{owner: owner} = payload, _status, _headers) do
      send(owner, :closed_adapter_send_chunked)
      {:ok, "", payload}
    end

    def chunk(_payload, _body), do: {:error, :closed}
  end

  defmodule OversizedOriginBody do
    def call(conn, _) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "123456")
    end
  end

  defmodule InvalidOriginImage do
    def call(conn, _) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "not actually a png")
    end
  end

  defmodule CorruptTailOriginImage do
    def call(conn, _) do
      body = File.read!("priv/static/images/cat-300.jpg")
      prefix_size = max(byte_size(body) - 64, 1)
      body = binary_part(body, 0, prefix_size) <> :binary.copy(<<0>>, 64)

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule ChunkedOriginImage do
    def call(conn, _) do
      body = File.read!("priv/static/images/cat-300.jpg")

      conn =
        conn
        |> Plug.Conn.put_resp_content_type("image/jpeg")
        |> Plug.Conn.send_chunked(200)

      midpoint = div(byte_size(body), 2)
      {:ok, conn} = Plug.Conn.chunk(conn, binary_part(body, 0, midpoint))
      {:ok, conn} = Plug.Conn.chunk(conn, binary_part(body, midpoint, byte_size(body) - midpoint))
      conn
    end
  end

  defmodule RecordingImageOpen do
    # ImagePlug decodes in the caller process, so self() is the test process here.
    def open(stream, opts) do
      send(self(), {:image_open_options, opts})
      Image.open(stream, opts)
    end
  end

  defmodule RejectingImageOpen do
    def open(_stream, _opts), do: raise("source negotiation should happen before decode")
  end

  defmodule FailingMaterializer do
    def materialize(_image), do: {:error, :forced_materialization_failure}
  end

  def sample_processing_request do
    %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat-300.jpg"]
    }
  end

  defmodule BrokenImageParser do
    @behaviour ImagePlug.ParamParser

    @impl ImagePlug.ParamParser
    def parse(_conn) do
      request =
        ImagePlug.ImagePlugTest.sample_processing_request()
        |> Map.put(:format, :jpeg)

      {:ok, request}
    end

    @impl ImagePlug.ParamParser
    def handle_error(conn, _error), do: conn
  end

  defmodule BrokenImagePlanner do
    def plan(%ProcessingRequest{}) do
      {:ok, [{ImagePlug.ImagePlugTest.BrokenImageTransform, nil}]}
    end
  end

  defmodule BrokenImageTransform do
    def execute(%ImagePlug.TransformState{} = state, _params) do
      %ImagePlug.TransformState{state | image: :not_an_image, output: :jpeg}
    end
  end

  defmodule RaisingAfterFirstChunkParser do
    @behaviour ImagePlug.ParamParser

    @impl ImagePlug.ParamParser
    def parse(_conn) do
      request =
        ImagePlug.ImagePlugTest.sample_processing_request()
        |> Map.put(:format, :jpeg)

      {:ok, request}
    end

    @impl ImagePlug.ParamParser
    def handle_error(conn, _error), do: conn
  end

  defmodule UnsupportedSourceKindParser do
    @behaviour ImagePlug.ParamParser

    @impl ImagePlug.ParamParser
    def parse(_conn) do
      request =
        ImagePlug.ImagePlugTest.sample_processing_request()
        |> Map.put(:source_kind, :signed)

      {:ok, request}
    end

    @impl ImagePlug.ParamParser
    def handle_error(conn, _error), do: conn
  end

  defmodule RaisingAfterFirstChunkPlanner do
    def plan(%ProcessingRequest{}) do
      {:ok, [{ImagePlug.ImagePlugTest.RaisingAfterFirstChunkTransform, nil}]}
    end
  end

  defmodule RaisingAfterFirstChunkTransform do
    def execute(%ImagePlug.TransformState{} = state, _params) do
      %ImagePlug.TransformState{state | image: :image, output: :jpeg}
    end
  end

  defmodule FailingTransformParser do
    @behaviour ImagePlug.ParamParser

    @impl ImagePlug.ParamParser
    def parse(_conn) do
      request =
        ImagePlug.ImagePlugTest.sample_processing_request()
        |> Map.put(:format, :jpeg)

      {:ok, request}
    end

    @impl ImagePlug.ParamParser
    def handle_error(conn, _error), do: conn
  end

  defmodule FailingTransformPlanner do
    def plan(%ProcessingRequest{}) do
      {:ok, [{ImagePlug.ImagePlugTest.FailingTransform, nil}]}
    end
  end

  defmodule FailingTransform do
    def execute(%ImagePlug.TransformState{} = state, _params) do
      ImagePlug.TransformState.add_error(state, {__MODULE__, :failed})
    end
  end

  defmodule RaisingAfterFirstChunkImage do
    def stream!(:image, suffix: ".jpg") do
      Stream.resource(
        fn -> :first end,
        fn
          :first -> {["first chunk"], :raise}
          :raise -> raise "boom after first chunk"
        end,
        fn _ -> :ok end
      )
    end
  end

  defp start_cache_probe do
    test_pid = self()
    spawn_link(fn -> cache_probe_loop(test_pid, []) end)
  end

  defp cache_probe_loop(test_pid, messages) do
    receive do
      {:cache_get, _key} = message ->
        cache_probe_loop(test_pid, [message | messages])

      {:cache_put, _key, _entry} = message ->
        cache_probe_loop(test_pid, [message | messages])

      :origin_was_called = message ->
        cache_probe_loop(test_pid, [message | messages])

      {:flush, ref} ->
        messages
        |> Enum.reverse()
        |> Enum.each(&send(test_pid, &1))

        send(test_pid, {:cache_probe_flushed, ref})
        cache_probe_loop(test_pid, [])
    end
  end

  defp flush_cache_probe(cache_probe) do
    ref = make_ref()
    send(cache_probe, {:flush, ref})
    assert_receive {:cache_probe_flushed, ^ref}
  end

  defp assert_cache_get_output(expected_output) do
    assert_cache_get_output(expected_output, 20, [])
  end

  defp assert_cache_get_output(expected_output, 0, seen_outputs) do
    flunk(
      "expected cache lookup for #{inspect(expected_output)}, saw #{inspect(Enum.reverse(seen_outputs))}"
    )
  end

  defp assert_cache_get_output(expected_output, remaining, seen_outputs) do
    receive do
      {:cache_get, %ImagePlug.Cache.Key{} = key} ->
        output = key.material[:output]

        if output == expected_output do
          assert true
        else
          assert_cache_get_output(expected_output, remaining - 1, [output | seen_outputs])
        end
    after
      0 ->
        flunk(
          "expected cache lookup for #{inspect(expected_output)}, saw #{inspect(Enum.reverse(seen_outputs))}"
        )
    end
  end

  defp start_slow_partial_origin(test_pid, ref) do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, _request} = :gen_tcp.recv(socket, 0)

        body = File.read!("priv/static/images/cat-300.jpg")
        first_chunk = binary_part(body, 0, 128)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "content-type: image/jpeg\r\n",
            "transfer-encoding: chunked\r\n",
            "\r\n",
            chunked_body_chunk(first_chunk)
          ])

        send(test_pid, {ref, :first_chunk_sent, self()})
        await_slow_partial_origin_close(ref, socket, listen_socket)
      end)

    {"http://127.0.0.1:#{port}", server}
  end

  defp chunked_body_chunk(body) do
    [Integer.to_string(byte_size(body), 16), "\r\n", body, "\r\n"]
  end

  defp await_slow_partial_origin_close(ref, socket, listen_socket) do
    receive do
      {^ref, :close} ->
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
    after
      5_000 ->
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
    end
  end

  test "no cache configured preserves the streaming response path" do
    conn = conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg")
    test_pid = self()

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        image_module: StreamingOnlyImage,
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [
          plug: fn conn -> CountingOriginImage.call(conn, test_pid: test_pid) end
        ]
      )

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == "streamed jpeg"
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert_received {:plug_conn, :sent}
    assert_received :stream_encoder_called
    refute_received :memory_encoder_called
  end

  test "streaming sends headers once and resumes for subsequent chunks" do
    conn = conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg")
    test_pid = self()

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        image_module: MultiChunkStreamingImage,
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [
          plug: fn conn -> CountingOriginImage.call(conn, test_pid: test_pid) end
        ]
      )

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == "first chunksecond chunk"
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert_received {:plug_conn, :sent}
    refute_received {:plug_conn, :sent}
    assert_received :stream_encoder_called
  end

  test "closed chunk delivery returns the started chunked response" do
    conn =
      :get
      |> conn("/_/f:jpeg/plain/images/cat-300.jpg")
      |> Map.put(:adapter, {ClosedChunkAdapter, %{owner: self()}})

    test_pid = self()

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        image_module: StreamingOnlyImage,
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [
          plug: fn conn -> CountingOriginImage.call(conn, test_pid: test_pid) end
        ]
      )

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == ""
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert_received :closed_adapter_send_chunked
    assert_received :stream_encoder_called
  end

  test "automatic source-format output does not require encoder overrides before streaming" do
    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/jpeg")

    test_pid = self()

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        image_module: StreamingOnlyImage,
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [
          plug: fn conn -> CountingOriginImage.call(conn, test_pid: test_pid) end
        ]
      )

    assert conn.status == 200
    assert conn.state == :chunked
    assert conn.resp_body == "streamed jpeg"
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert_received :stream_encoder_called
  end

  test "does not touch cache when parser validation fails" do
    conn = conn(:get, "/_/w:-1/plain/images/cat-300.jpg")
    cache_probe = start_cache_probe()

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 400
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "does not touch cache when planner validation fails" do
    conn = conn(:get, "/_/rs:auto:100:100/plain/images/cat-300.jpg")
    cache_probe = start_cache_probe()

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 400
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "serves cache hits without fetching origin" do
    cache_probe = start_cache_probe()

    cached_entry = %ImagePlug.Cache.Entry{
      body: "cached image",
      content_type: "image/webp",
      headers: [{"Vary", "Accept"}, {"connection", "close"}],
      created_at: DateTime.utc_now()
    }

    conn = conn(:get, "/_/f:webp/plain/images/cat-300.jpg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        cache: {CacheProbe, message_target: cache_probe, get_result: {:hit, cached_entry}},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached image"
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "vary") == ["Accept"]
    assert get_resp_header(conn, "connection") == []
    assert_received {:cache_get, key}
    assert key.material[:origin_identity] == "http://origin.test/images/cat-300.jpg"
    refute_received :origin_was_called
  end

  test "cache misses process origin response, write entry, and send encoded body" do
    conn = conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg")
    test_pid = self()
    cache_probe = start_cache_probe()

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [
          plug: fn conn -> CountingOriginImage.call(conn, test_pid: test_pid) end
        ]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert byte_size(conn.resp_body) > 0
    assert_received {:cache_get, key}
    assert_received {:cache_put, ^key, entry}
    assert_received {:plug_conn, :sent}
    assert entry.content_type == "image/jpeg"
    assert entry.headers == []
    assert entry.body == conn.resp_body
  end

  test "cache misses for auto output store vary header and selected content type" do
    test_pid = self()
    cache_probe = start_cache_probe()

    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/jpeg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [
          plug: fn conn -> CountingOriginImage.call(conn, test_pid: test_pid) end
        ]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "vary") == ["Accept"]
    assert_received {:cache_put, _key, entry}
    assert entry.content_type == "image/jpeg"
    assert entry.headers == [{"vary", "Accept"}]
  end

  test "does not fetch origin when parser validation fails" do
    conn = conn(:get, "/_/w:-1/plain/images/cat-300.jpg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    assert conn.status == 400
    refute_received :origin_was_called
  end

  test "does not fetch origin when planner validation fails" do
    conn = conn(:get, "/_/rs:auto:100:100/plain/images/cat-300.jpg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    assert conn.status == 400
    refute_received :origin_was_called
  end

  test "returns an origin error for unsupported source kinds" do
    conn = conn(:get, "/_/signed/images/cat-300.jpg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: UnsupportedSourceKindParser,
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    assert conn.status == 502
    assert conn.resp_body == "error fetching origin image"
    refute_received :origin_was_called
  end

  test "auto output negotiates content type from Accept and sets Vary" do
    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/jpeg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "automatic fallback selects accepted source format" do
    {:ok, image} = Image.new(20, 20, color: :white)
    body = Image.write!(image, :memory, suffix: ".png")

    origin = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end

    conn =
      :get
      |> conn("/_/plain/images/cat.png")
      |> put_req_header("accept", "image/png")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: origin]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "processes an imgproxy fill URL with explicit output extension" do
    conn = conn(:get, "/_/rs:fill:100:100/g:ce/plain/images/cat-300.jpg@jpeg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "vary") == []
  end

  test "automatic output uses server preference over relative q-values" do
    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.1")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/avif"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "exact Accept exclusion overrides wildcard allowance" do
    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/avif;q=0,image/*;q=1")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "automatic AVIF cache hits do not fetch origin" do
    cache_probe = start_cache_probe()

    cached_entry = %ImagePlug.Cache.Entry{
      body: "cached avif",
      content_type: "image/avif",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/avif,image/webp")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        cache: {CacheProbe, message_target: cache_probe, get_result: {:hit, cached_entry}},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached avif"

    assert_cache_get_output(
      mode: :automatic,
      accept: [avif: true, webp: true, jpeg: false, png: false],
      auto: [avif: true, webp: true]
    )

    refute_received :origin_was_called
  end

  test "automatic JPEG source-format cache hits do not fetch origin" do
    cache_probe = start_cache_probe()

    cached_entry = %ImagePlug.Cache.Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/jpeg")

    get_result_fun = fn key ->
      case key.material[:output] do
        [
          mode: :automatic,
          accept: [avif: false, webp: false, jpeg: true, png: false],
          auto: [avif: true, webp: true]
        ] ->
          {:hit, cached_entry}

        _other ->
          :miss
      end
    end

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        cache: {CacheProbe, message_target: cache_probe, get_result_fun: get_result_fun},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached jpeg"

    assert_cache_get_output(
      mode: :automatic,
      accept: [avif: false, webp: false, jpeg: true, png: false],
      auto: [avif: true, webp: true]
    )

    refute_received :origin_was_called
  end

  test "deferred source-format cache hits can serve disabled modern formats without origin" do
    cache_probe = start_cache_probe()

    cached_entry = %ImagePlug.Cache.Entry{
      body: "cached source avif",
      content_type: "image/avif",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/avif")

    get_result_fun = fn key ->
      case key.material[:output] do
        [
          mode: :automatic,
          accept: [avif: true, webp: false, jpeg: false, png: false],
          auto: [avif: false, webp: false]
        ] ->
          {:hit, cached_entry}

        _other ->
          :miss
      end
    end

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        auto_avif: false,
        auto_webp: false,
        cache: {CacheProbe, message_target: cache_probe, get_result_fun: get_result_fun},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached source avif"

    assert_cache_get_output(
      mode: :automatic,
      accept: [avif: true, webp: false, jpeg: false, png: false],
      auto: [avif: false, webp: false]
    )

    refute_received :origin_was_called
  end

  test "automatic cache key is available before origin when modern formats are disabled" do
    cache_probe = start_cache_probe()

    cached_entry = %ImagePlug.Cache.Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/*")

    get_result_fun = fn key ->
      case key.material[:output] do
        [
          mode: :automatic,
          accept: [avif: true, webp: true, jpeg: true, png: true],
          auto: [avif: false, webp: false]
        ] ->
          {:hit, cached_entry}

        _other ->
          :miss
      end
    end

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        auto_avif: false,
        auto_webp: false,
        cache: {CacheProbe, message_target: cache_probe, get_result_fun: get_result_fun},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert conn.resp_body == "cached jpeg"

    assert_cache_get_output(
      mode: :automatic,
      accept: [avif: true, webp: true, jpeg: true, png: true],
      auto: [avif: false, webp: false]
    )

    refute_received :origin_was_called
  end

  test "disabled automatic modern formats still set Vary for negotiated source output" do
    conn = conn(:get, "/_/plain/images/cat-300.jpg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        auto_avif: false,
        auto_webp: false,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "disabled automatic modern formats set Vary on unacceptable source output" do
    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/jpeg;q=0")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        auto_avif: false,
        auto_webp: false,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 406
    assert conn.resp_body == "no acceptable image output format"
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "deferred automatic negotiation rejects unacceptable source type before decoding" do
    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/png")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        auto_avif: false,
        auto_webp: false,
        image_open_module: RejectingImageOpen,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 406
    assert conn.resp_body == "no acceptable image output format"
  end

  test "does not touch cache or origin when planner rejects unsupported semantics" do
    conn = conn(:get, "/_/rs:auto:100:100/plain/images/cat-300.jpg")
    cache_probe = start_cache_probe()

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        cache: {CacheProbe, message_target: cache_probe},
        origin_req_options: [plug: OriginShouldNotBeCalled]
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 400
    refute_received {:cache_get, _key}
    refute_received :origin_was_called
  end

  test "explicit output format does not set Vary on uncached streaming responses" do
    conn =
      ImagePlug.call(
        conn(:get, "/_/f:webp/plain/images/cat-300.jpg"),
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "vary") == []
  end

  test "auto output returns 406 when Accept excludes every supported output" do
    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/*;q=0")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 406
    assert conn.resp_body == "no acceptable image output format"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "safe one-pass resize opens origin with sequential access" do
    conn =
      conn(:get, "/_/rt:force/w:100/format:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert_received {:image_open_options, opts}
    assert Keyword.get(opts, :access) == :sequential
    assert Keyword.get(opts, :fail_on) == :error
  end

  test "cover opens origin with random access" do
    conn =
      conn(:get, "/_/rs:fill:100:100/f:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert_received {:image_open_options, opts}
    assert Keyword.get(opts, :access) == :random
    assert Keyword.get(opts, :fail_on) == :error
  end

  test "sequential materialization failure without origin error returns decode error" do
    conn =
      conn(:get, "/_/rt:force/w:100/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
        param_parser: ImagePlug.ParamParser.Native,
        image_materializer_module: FailingMaterializer,
        origin_req_options: [plug: OriginImage]
      )

    assert_received {:image_open_options, opts}
    assert Keyword.get(opts, :access) == :sequential
    assert Keyword.get(opts, :fail_on) == :error
    assert conn.status == 415
    assert conn.state == :sent
    assert conn.resp_body == "origin response is not a supported image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "deferred automatic sequential materialization failure returns decode error" do
    conn =
      :get
      |> conn("/_/rt:force/w:100/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/jpeg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        image_open_module: RecordingImageOpen,
        param_parser: ImagePlug.ParamParser.Native,
        image_materializer_module: FailingMaterializer,
        origin_req_options: [plug: OriginImage]
      )

    assert_received {:image_open_options, opts}
    assert Keyword.get(opts, :access) == :sequential
    assert Keyword.get(opts, :fail_on) == :error
    assert conn.status == 415
    assert conn.state == :sent
    assert conn.resp_body == "origin response is not a supported image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "processes a native path URL with dimensions and explicit output format" do
    conn = conn(:get, "/_/w:100/h:100/f:jpeg/plain/images/cat-300.jpg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
  end

  test "returns text 500 when encoding fails before sending chunked headers" do
    conn = conn(:get, "/_/plain/images/cat-300.jpg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: BrokenImageParser,
        pipeline_planner: BrokenImagePlanner,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 500
    assert conn.resp_body == "error encoding image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "returns text 500 when encoder produces an empty stream" do
    conn = conn(:get, "/_/plain/images/cat-300.jpg")

    log =
      capture_log(fn ->
        conn =
          ImagePlug.call(conn,
            root_url: "http://origin.test",
            image_module: EmptyStreamingImage,
            param_parser: RaisingAfterFirstChunkParser,
            pipeline_planner: RaisingAfterFirstChunkPlanner,
            origin_req_options: [plug: OriginImage]
          )

        assert conn.status == 500
        assert conn.state == :sent
        assert conn.resp_body == "error encoding image"
        assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
      end)

    assert log =~ "encode_error: image encoder produced an empty stream"
    assert_received :stream_encoder_called
  end

  test "does not send text 500 when encoding fails after chunked response starts" do
    conn = conn(:get, "/_/plain/images/cat-300.jpg")

    log =
      capture_log(fn ->
        conn =
          ImagePlug.call(conn,
            root_url: "http://origin.test",
            image_module: RaisingAfterFirstChunkImage,
            param_parser: RaisingAfterFirstChunkParser,
            pipeline_planner: RaisingAfterFirstChunkPlanner,
            origin_req_options: [plug: OriginImage]
          )

        assert conn.status == 200
        assert conn.state == :chunked
        assert conn.resp_body == "first chunk"
        assert get_resp_header(conn, "content-type") == ["image/jpeg"]
      end)

    assert log =~ "encode_error:"
    assert log =~ "boom after first chunk"
  end

  test "transform errors return a stable client message and log details" do
    conn = conn(:get, "/_/plain/images/cat-300.jpg")

    log =
      capture_log(fn ->
        conn =
          ImagePlug.call(conn,
            root_url: "http://origin.test",
            param_parser: FailingTransformParser,
            pipeline_planner: FailingTransformPlanner,
            origin_req_options: [plug: OriginImage]
          )

        assert conn.status == 422
        assert conn.resp_body == "invalid image transform"
        assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
      end)

    assert log =~ "transform_error(s):"
    assert log =~ "ImagePlug.ImagePlugTest.FailingTransform"
  end

  test "rejects decoded images above the configured pixel limit" do
    {:ok, image} = Image.new(20, 20, color: :white)
    body = Image.write!(image, :memory, suffix: ".png")

    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end

    conn =
      conn(:get, "/_/w:10/plain/images/large.png")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        max_input_pixels: 399,
        origin_req_options: [plug: plug]
      )

    assert conn.status == 413
    assert conn.resp_body == "origin image is too large"
  end

  test "honors top-level max_body_bytes for origin fetches" do
    conn =
      conn(:get, "/_/plain/images/large-body.png")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        max_body_bytes: 5,
        origin_req_options: [plug: OversizedOriginBody]
      )

    assert conn.status == 502
    assert conn.resp_body == "error fetching origin image"
  end

  test "honors max_body_bytes for valid image bytes while streaming into decode" do
    body = File.read!("priv/static/images/cat-300.jpg")

    conn =
      conn(:get, "/_/plain/images/large-body.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        max_body_bytes: byte_size(body) - 1,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 502
    assert conn.resp_body == "error fetching origin image"
  end

  test "origin timeout while decoding a partial valid image remains an origin error" do
    ref = make_ref()
    {root_url, server} = start_slow_partial_origin(self(), ref)
    monitor_ref = Process.monitor(server)

    conn =
      conn(:get, "/_/plain/images/slow.jpg")
      |> ImagePlug.call(
        root_url: root_url,
        param_parser: ImagePlug.ParamParser.Native,
        origin_receive_timeout: 50
      )

    assert_receive {^ref, :first_chunk_sent, ^server}
    assert conn.status == 502
    assert conn.resp_body == "error fetching origin image"

    send(server, {ref, :close})
    assert_receive {:DOWN, ^monitor_ref, :process, ^server, _reason}
  end

  test "sequential body limit after initial valid bytes remains an origin error before image headers" do
    body = File.read!("priv/static/images/cat-300.jpg")

    conn =
      conn(:get, "/_/rt:force/w:100/plain/images/large-body.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        max_body_bytes: byte_size(body) - 1,
        origin_req_options: [plug: ChunkedOriginImage]
      )

    assert conn.status == 502
    assert conn.state == :sent
    assert conn.resp_body == "error fetching origin image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "sequential timeout after initial valid bytes remains an origin error before image headers" do
    ref = make_ref()
    {root_url, server} = start_slow_partial_origin(self(), ref)
    monitor_ref = Process.monitor(server)

    conn =
      conn(:get, "/_/rt:force/w:100/plain/images/slow.jpg")
      |> ImagePlug.call(
        root_url: root_url,
        param_parser: ImagePlug.ParamParser.Native,
        origin_receive_timeout: 50
      )

    assert_receive {^ref, :first_chunk_sent, ^server}
    assert conn.status == 502
    assert conn.state == :sent
    assert conn.resp_body == "error fetching origin image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

    send(server, {ref, :close})
    assert_receive {:DOWN, ^monitor_ref, :process, ^server, _reason}
  end

  test "sequential corrupt image tail without origin error remains a decode error" do
    conn =
      conn(:get, "/_/rt:force/w:100/plain/images/corrupt-tail.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: CorruptTailOriginImage]
      )

    assert conn.status == 415
    assert conn.state == :sent
    assert conn.resp_body == "origin response is not a supported image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "invalid streamed image bytes are decode errors" do
    conn =
      conn(:get, "/_/plain/images/broken.png")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: InvalidOriginImage]
      )

    assert conn.status == 415
    assert conn.resp_body == "origin response is not a supported image"
  end

  test "cache read errors fail open by default and continue to origin" do
    cache_probe = start_cache_probe()

    conn =
      conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache: {CacheProbe, message_target: cache_probe, get_result: {:error, :read_failed}}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert_received :origin_was_called
    assert_received {:cache_put, _key, _entry}
  end

  test "cache read errors fail before origin when fail_on_cache_error is true" do
    cache_probe = start_cache_probe()

    conn =
      conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache:
          {CacheProbe,
           message_target: cache_probe,
           get_result: {:error, :read_failed},
           fail_on_cache_error: true}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 500
    assert conn.resp_body == "cache error"
    refute_received :origin_was_called
  end

  test "cache write errors fail open by default and still return response" do
    cache_probe = start_cache_probe()

    conn =
      conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache: {CacheProbe, message_target: cache_probe, put_result: {:error, :write_failed}}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert byte_size(conn.resp_body) > 0
    assert_received :origin_was_called
    assert_received {:cache_put, _key, _entry}
  end

  test "cache write errors fail before response when fail_on_cache_error is true" do
    cache_probe = start_cache_probe()

    conn =
      conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache:
          {CacheProbe,
           message_target: cache_probe,
           put_result: {:error, :write_failed},
           fail_on_cache_error: true}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 500
    assert conn.resp_body == "cache error"
    assert_received :origin_was_called
    assert_received {:cache_put, _key, _entry}
  end

  test "automatic cache write errors preserve negotiated Vary when fail_on_cache_error is true" do
    cache_probe = start_cache_probe()

    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/jpeg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache:
          {CacheProbe,
           message_target: cache_probe,
           put_result: {:error, :write_failed},
           fail_on_cache_error: true}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 500
    assert conn.resp_body == "cache error"
    assert get_resp_header(conn, "vary") == ["Accept"]
    assert_received :origin_was_called
    assert_received {:cache_put, _key, _entry}
  end

  test "cache writes over max_body_bytes are skipped and still return response" do
    cache_probe = start_cache_probe()

    conn =
      conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache: {CacheProbe, message_target: cache_probe, max_body_bytes: 1}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 200
    assert byte_size(conn.resp_body) > 1
    refute_received {:cache_put, _key, _entry}
  end

  test "unsuccessful processed responses are not cached" do
    cache_probe = start_cache_probe()

    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> put_req_header("accept", "image/*;q=0")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache: {CacheProbe, message_target: cache_probe}
      )

    flush_cache_probe(cache_probe)
    assert conn.status == 406
    assert conn.resp_body == "no acceptable image output format"
    refute_received :origin_was_called
    refute_received {:cache_put, _key, _entry}
  end

  test "filesystem cache persists processed responses across requests" do
    cache_root =
      Path.join(
        System.tmp_dir!(),
        "image_plug_integration_cache_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(cache_root)
    File.mkdir_p!(cache_root)

    try do
      cache_probe = start_cache_probe()

      opts = [
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        origin_req_options: [plug: {CountingOriginImage, test_pid: cache_probe}],
        cache:
          {ImagePlug.Cache.FileSystem,
           root: cache_root,
           path_prefix: "processed",
           max_body_bytes: 10_000_000,
           key_headers: [],
           key_cookies: [],
           fail_on_cache_error: false}
      ]

      first_conn =
        conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg")
        |> ImagePlug.call(opts)

      flush_cache_probe(cache_probe)
      assert first_conn.status == 200
      assert_received :origin_was_called

      second_conn =
        conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg")
        |> ImagePlug.call(opts)

      flush_cache_probe(cache_probe)
      assert second_conn.status == 200
      assert second_conn.resp_body == first_conn.resp_body
      refute_received :origin_was_called
    after
      File.rm_rf!(cache_root)
    end
  end
end
