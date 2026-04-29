defmodule ImagePlug.ParamParser.NativeTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.ParamParser.Native
  alias ImagePlug.ProcessingRequest

  test "parses a plain source with no options" do
    conn = conn(:get, "/_/plain/images/cat.jpg")

    assert {:ok,
            %ProcessingRequest{
              signature: "_",
              source_kind: :plain,
              source_path: ["images", "cat.jpg"],
              format: :auto,
              focus: {:anchor, :center, :center}
            }} = Native.parse(conn)
  end

  test "parses native options into a processing request" do
    conn =
      conn(
        :get,
        "/_/fit:cover/w:300/h:200/focus:50p:25p/format:webp/plain/images/cat.jpg"
      )

    assert {:ok,
            %ProcessingRequest{
              signature: "_",
              source_kind: :plain,
              source_path: ["images", "cat.jpg"],
              fit: :cover,
              width: {:pixels, 300},
              height: {:pixels, 200},
              focus: {:coordinate, {:percent, 50}, {:percent, 25}},
              format: :webp
            }} = Native.parse(conn)
  end

  test "parses all native focus anchors" do
    assert {:ok, %ProcessingRequest{focus: {:anchor, :center, :center}}} =
             conn(:get, "/_/focus:center/plain/images/cat.jpg") |> Native.parse()

    assert {:ok, %ProcessingRequest{focus: {:anchor, :center, :top}}} =
             conn(:get, "/_/focus:top/plain/images/cat.jpg") |> Native.parse()

    assert {:ok, %ProcessingRequest{focus: {:anchor, :center, :bottom}}} =
             conn(:get, "/_/focus:bottom/plain/images/cat.jpg") |> Native.parse()

    assert {:ok, %ProcessingRequest{focus: {:anchor, :left, :center}}} =
             conn(:get, "/_/focus:left/plain/images/cat.jpg") |> Native.parse()

    assert {:ok, %ProcessingRequest{focus: {:anchor, :right, :center}}} =
             conn(:get, "/_/focus:right/plain/images/cat.jpg") |> Native.parse()
  end

  test "treats option-like segments after plain as source path" do
    conn = conn(:get, "/_/plain/images/w:300/cat.jpg")

    assert {:ok, %ProcessingRequest{source_path: ["images", "w:300", "cat.jpg"]}} =
             Native.parse(conn)
  end

  test "option order does not affect the parsed request" do
    first =
      conn(:get, "/_/fit:cover/w:300/h:200/focus:top/format:png/plain/images/cat.jpg")
      |> Native.parse()

    second =
      conn(:get, "/_/format:png/focus:top/h:200/w:300/fit:cover/plain/images/cat.jpg")
      |> Native.parse()

    assert first == second
  end

  test "supports unsafe as the development signature segment" do
    conn = conn(:get, "/unsafe/w:300/plain/images/cat.jpg")

    assert {:ok, %ProcessingRequest{signature: "unsafe", width: {:pixels, 300}}} =
             Native.parse(conn)
  end

  test "rejects unsupported signature segments" do
    conn = conn(:get, "/signed-value/plain/images/cat.jpg")

    assert Native.parse(conn) == {:error, {:unsupported_signature, "signed-value"}}
  end

  test "rejects missing source kind" do
    conn = conn(:get, "/_/w:300")

    assert Native.parse(conn) == {:error, :missing_source_kind}
  end

  test "rejects missing plain source identifier" do
    conn = conn(:get, "/_/w:300/plain")

    assert Native.parse(conn) == {:error, {:missing_source_identifier, "plain"}}
  end

  test "rejects unknown options" do
    conn = conn(:get, "/_/resize:300/plain/images/cat.jpg")

    assert Native.parse(conn) == {:error, {:unknown_option, "resize"}}
  end

  test "rejects duplicate options" do
    conn = conn(:get, "/_/w:300/w:400/plain/images/cat.jpg")

    assert Native.parse(conn) == {:error, {:duplicate_option, :width}}
  end

  test "rejects invalid dimensions" do
    conn = conn(:get, "/_/w:0/plain/images/cat.jpg")

    assert Native.parse(conn) == {:error, {:invalid_positive_integer, "0"}}
  end

  test "rejects blurhash as a native image format" do
    conn = conn(:get, "/_/format:blurhash/plain/images/cat.jpg")

    assert Native.parse(conn) ==
             {:error, {:invalid_format, "blurhash", ["auto", "webp", "avif", "jpeg", "png"]}}
  end

  test "renders native parser errors as text 400 responses" do
    conn = conn(:get, "/_/resize:300/plain/images/cat.jpg")

    conn = Native.handle_error(conn, {:error, {:unknown_option, "resize"}})

    assert conn.status == 400
    assert conn.resp_body == "invalid image request: {:unknown_option, \"resize\"}"
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
  end
end
