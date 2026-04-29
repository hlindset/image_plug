defmodule ImagePlug.ImagePlugTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  doctest ImagePlug

  alias ImagePlug.ProcessingRequest

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

  defmodule OversizedOriginBody do
    def call(conn, _) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "123456")
    end
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
      {:ok, ImagePlug.ImagePlugTest.sample_processing_request()}
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
      {:ok, ImagePlug.ImagePlugTest.sample_processing_request()}
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

  test "does not fetch origin when parser validation fails" do
    conn = conn(:get, "/_/w:0/plain/images/cat-300.jpg")

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
    conn = conn(:get, "/_/fit:cover/w:100/plain/images/cat-300.jpg")

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

  test "processes a native path URL with cover and explicit output format" do
    conn = conn(:get, "/_/fit:cover/w:100/h:100/format:jpeg/plain/images/cat-300.jpg")

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

  test "rejects decoded images above the configured pixel limit" do
    {:ok, image} = Image.new(20, 20, color: :white)
    body = Image.write!(image, :memory, suffix: ".png")

    Req.Test.stub(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end)

    conn =
      conn(:get, "/_/w:10/plain/images/large.png")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Native,
        max_input_pixels: 399,
        origin_req_options: [plug: {Req.Test, __MODULE__}]
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
end
