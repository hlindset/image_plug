defmodule ImagePlug.ImagePlugTest do
  use ExUnit.Case, async: true
  use Plug.Test

  import ExUnit.CaptureLog

  doctest ImagePlug

  defmodule OriginShouldNotBeCalled do
    def call(conn) do
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

  defmodule BrokenImageParser do
    @behaviour ImagePlug.ParamParser

    @impl ImagePlug.ParamParser
    def parse(_conn), do: {:ok, [{ImagePlug.ImagePlugTest.BrokenImageTransform, nil}]}

    @impl ImagePlug.ParamParser
    def handle_error(conn, _error), do: conn
  end

  defmodule BrokenImageTransform do
    def execute(%ImagePlug.TransformState{} = state, _params) do
      %ImagePlug.TransformState{state | image: :not_an_image, output: :jpeg}
    end
  end

  defmodule RaisingAfterFirstChunkParser do
    @behaviour ImagePlug.ParamParser

    @impl ImagePlug.ParamParser
    def parse(_conn), do: {:ok, [{ImagePlug.ImagePlugTest.RaisingAfterFirstChunkTransform, nil}]}

    @impl ImagePlug.ParamParser
    def handle_error(conn, _error), do: conn
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

  test "auto output negotiates content type from Accept and sets Vary" do
    conn =
      :get
      |> conn("/process/images/cat-300.jpg")
      |> put_req_header("accept", "image/png;q=0")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Twicpics,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "auto output returns 406 when Accept excludes every supported output" do
    conn =
      :get
      |> conn("/process/images/cat-300.jpg")
      |> put_req_header("accept", "image/*;q=0")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Twicpics,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 406
    assert conn.resp_body == "no acceptable image output format"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert get_resp_header(conn, "vary") == ["Accept"]
  end

  test "returns text 500 when encoding fails before sending chunked headers" do
    conn = conn(:get, "/process/images/cat-300.jpg")

    conn =
      ImagePlug.call(conn,
        root_url: "http://origin.test",
        param_parser: BrokenImageParser,
        origin_req_options: [plug: OriginImage]
      )

    assert conn.status == 500
    assert conn.resp_body == "error encoding image"
    assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "does not send text 500 when encoding fails after chunked response starts" do
    conn = conn(:get, "/process/images/cat-300.jpg")

    log =
      capture_log(fn ->
        conn =
          ImagePlug.call(conn,
            root_url: "http://origin.test",
            image_module: RaisingAfterFirstChunkImage,
            param_parser: RaisingAfterFirstChunkParser,
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
      conn(:get, "/process/images/large.png?twic=v1/resize=10")
      |> ImagePlug.call(
        root_url: "http://origin.test",
        param_parser: ImagePlug.ParamParser.Twicpics,
        max_input_pixels: 399,
        origin_req_options: [plug: {Req.Test, __MODULE__}]
      )

    assert conn.status == 413
    assert conn.resp_body == "origin image is too large"
  end
end
