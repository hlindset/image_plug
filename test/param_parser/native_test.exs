defmodule ImagePlug.ParamParser.NativeTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.ParamParser.Native
  alias ImagePlug.ProcessingRequest

  test "parses a plain source with no processing options" do
    conn = conn(:get, "/_/plain/images/cat.jpg")

    assert {:ok,
            %ProcessingRequest{
              signature: "_",
              source_kind: :plain,
              source_path: ["images", "cat.jpg"],
              resizing_type: :fit,
              width: nil,
              height: nil,
              gravity: {:anchor, :center, :center},
              format: nil
            }} = Native.parse(conn)
  end

  test "supports unsafe as the disabled-signing signature segment" do
    assert {:ok, %ProcessingRequest{signature: "unsafe"}} =
             conn(:get, "/unsafe/plain/images/cat.jpg") |> Native.parse()
  end

  test "rejects unsupported signature segments while signing is disabled" do
    assert Native.parse(conn(:get, "/signed-value/plain/images/cat.jpg")) ==
             {:error, {:unsupported_signature, "signed-value"}}
  end

  test "rejects missing signature" do
    assert Native.parse(conn(:get, "/")) == {:error, :missing_signature}
  end

  test "rejects missing source kind" do
    assert Native.parse(conn(:get, "/_/w:300")) == {:error, :missing_source_kind}
  end

  test "rejects missing plain source identifier" do
    assert Native.parse(conn(:get, "/_/plain")) ==
             {:error, {:missing_source_identifier, "plain"}}
  end

  test "treats option-like segments after plain as source path" do
    assert {:ok, %ProcessingRequest{source_path: ["images", "w:300", "cat.jpg"]}} =
             conn(:get, "/_/plain/images/w:300/cat.jpg") |> Native.parse()
  end

  test "parses resize and rs full grammar" do
    assert {:ok,
            %ProcessingRequest{
              resizing_type: :fill,
              width: {:pixels, 300},
              height: {:pixels, 200},
              enlarge: true,
              extend: false
            }} = conn(:get, "/_/resize:fill:300:200:1:0/plain/images/cat.jpg") |> Native.parse()

    assert {:ok,
            %ProcessingRequest{
              resizing_type: :force,
              width: {:pixels, 300},
              height: {:pixels, 200}
            }} = conn(:get, "/_/rs:force:300:200/plain/images/cat.jpg") |> Native.parse()
  end

  test "parses omitted resize arguments with imgproxy defaults" do
    assert {:ok, %ProcessingRequest{resizing_type: :fit, width: {:pixels, 300}, height: nil}} =
             conn(:get, "/_/rs:fit:300/plain/images/cat.jpg") |> Native.parse()

    assert {:ok,
            %ProcessingRequest{
              resizing_type: :fit,
              width: {:pixels, 300},
              height: {:pixels, 200}
            }} =
             conn(:get, "/_/rs::300:200/plain/images/cat.jpg") |> Native.parse()
  end

  test "omitted meta-option arguments do not overwrite previous field assignments" do
    assert {:ok,
            %ProcessingRequest{
              resizing_type: :fill,
              width: {:pixels, 500},
              height: {:pixels, 200}
            }} = conn(:get, "/_/w:500/rs:fill::200/plain/images/cat.jpg") |> Native.parse()
  end

  test "omitted extend argument still parses provided extend gravity tail" do
    assert {:ok,
            %ProcessingRequest{
              extend: false,
              extend_gravity: {:anchor, :center, :center},
              extend_x_offset: nil,
              extend_y_offset: nil
            }} =
             conn(:get, "/_/rs::::::ce::/plain/images/cat.jpg") |> Native.parse()

    assert {:ok,
            %ProcessingRequest{
              extend: false,
              extend_gravity: {:anchor, :center, :center},
              extend_x_offset: nil,
              extend_y_offset: nil
            }} =
             conn(:get, "/_/s:::::ce::/plain/images/cat.jpg") |> Native.parse()
  end

  test "extend gravity invalid arity reports the original option segment" do
    segment = "rs:::::1:ce:1"

    assert Native.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg")) ==
             {:error, {:invalid_option_segment, segment}}
  end

  test "parses extend gravity when extend is provided" do
    x_offset = 0.0
    y_offset = 0.0

    assert {:ok,
            %ProcessingRequest{
              resizing_type: :fit,
              width: {:pixels, 300},
              height: {:pixels, 200},
              extend: true,
              extend_gravity: {:anchor, :center, :center},
              extend_x_offset: ^x_offset,
              extend_y_offset: ^y_offset
            }} = conn(:get, "/_/rs:fit:300:200:0:1:ce:0:0/plain/images/cat.jpg") |> Native.parse()
  end

  test "parses size without changing resizing_type" do
    assert {:ok,
            %ProcessingRequest{
              resizing_type: :force,
              width: {:pixels, 300},
              height: {:pixels, 200}
            }} = conn(:get, "/_/rt:force/s:300:200/plain/images/cat.jpg") |> Native.parse()
  end

  test "size overwrites dimensions without resetting resizing_type" do
    assert {:ok,
            %ProcessingRequest{
              resizing_type: :fill,
              width: {:pixels, 100},
              height: {:pixels, 100}
            }} = conn(:get, "/_/rs:fill:300:200/s:100:100/plain/images/cat.jpg") |> Native.parse()
  end

  test "parses resizing type aliases and all documented values" do
    for {value, expected} <- [
          {"fit", :fit},
          {"fill", :fill},
          {"fill-down", :fill_down},
          {"force", :force},
          {"auto", :auto}
        ] do
      assert {:ok, %ProcessingRequest{resizing_type: ^expected}} =
               conn(:get, "/_/rt:#{value}/plain/images/cat.jpg") |> Native.parse()
    end
  end

  test "invalid resizing type reports supported values" do
    assert Native.parse(conn(:get, "/_/rt:crop/plain/images/cat.jpg")) ==
             {:error,
              {:invalid_resizing_type, "crop", ["fit", "fill", "fill-down", "force", "auto"]}}
  end

  test "parses width and height aliases including zero" do
    assert {:ok, %ProcessingRequest{width: {:pixels, 0}, height: {:pixels, 200}}} =
             conn(:get, "/_/w:0/h:200/plain/images/cat.jpg") |> Native.parse()
  end

  test "parses gravity anchors and focal point" do
    assert {:ok, %ProcessingRequest{gravity: {:anchor, :left, :top}}} =
             conn(:get, "/_/g:nowe/plain/images/cat.jpg") |> Native.parse()

    assert {:ok, %ProcessingRequest{gravity: {:fp, 0.5, 0.25}}} =
             conn(:get, "/_/gravity:fp:0.5:0.25/plain/images/cat.jpg") |> Native.parse()

    x = 1.0
    y = 0.0

    assert {:ok, %ProcessingRequest{gravity: {:fp, ^x, ^y}}} =
             conn(:get, "/_/g:fp:1:0/plain/images/cat.jpg") |> Native.parse()
  end

  test "rejects out-of-range focal point coordinates as gravity coordinate errors" do
    assert Native.parse(conn(:get, "/_/g:fp:1.2:0.5/plain/images/cat.jpg")) ==
             {:error, {:invalid_gravity_coordinate, "1.2"}}

    assert Native.parse(conn(:get, "/_/g:fp:nope:0.5/plain/images/cat.jpg")) ==
             {:error, {:invalid_gravity_coordinate, "nope"}}
  end

  test "parses smart gravity for planner rejection" do
    assert {:ok, %ProcessingRequest{gravity: :sm}} =
             conn(:get, "/_/g:sm/plain/images/cat.jpg") |> Native.parse()
  end

  test "parses format aliases and jpg normalization" do
    assert {:ok, %ProcessingRequest{format: :webp}} =
             conn(:get, "/_/f:webp/plain/images/cat.jpg") |> Native.parse()

    assert {:ok, %ProcessingRequest{format: :avif}} =
             conn(:get, "/_/f:avif/plain/images/cat.jpg") |> Native.parse()

    assert {:ok, %ProcessingRequest{format: :jpeg}} =
             conn(:get, "/_/ext:jpg/plain/images/cat.jpg") |> Native.parse()
  end

  test "plain source extension overrides explicit format after options" do
    assert {:ok,
            %ProcessingRequest{
              format: :png
            }} = conn(:get, "/_/f:webp/plain/images/cat.jpg@png") |> Native.parse()
  end

  test "dangling raw @ does not overwrite an explicit format" do
    assert {:ok,
            %ProcessingRequest{
              source_path: ["images", "cat.jpg"],
              format: :webp
            }} = conn(:get, "/_/f:webp/plain/images/cat.jpg@") |> Native.parse()
  end

  test "rejects format auto because it is not imgproxy grammar" do
    assert Native.parse(conn(:get, "/_/format:auto/plain/images/cat.jpg")) ==
             {:error, {:invalid_format, "auto", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
  end

  test "later field assignments overwrite earlier assignments" do
    assert {:ok,
            %ProcessingRequest{
              width: {:pixels, 200}
            }} = conn(:get, "/_/w:100/width:200/plain/images/cat.jpg") |> Native.parse()

    assert {:ok,
            %ProcessingRequest{
              resizing_type: :fill,
              width: {:pixels, 500},
              height: {:pixels, 200}
            }} =
             conn(:get, "/_/resize:fill:300:200/w:500/plain/images/cat.jpg") |> Native.parse()

    assert {:ok,
            %ProcessingRequest{
              resizing_type: :fill,
              width: {:pixels, 300},
              height: {:pixels, 200}
            }} =
             conn(:get, "/_/w:500/resize:fill:300:200/plain/images/cat.jpg") |> Native.parse()

    assert {:ok,
            %ProcessingRequest{
              resizing_type: :force,
              width: {:pixels, 300},
              height: {:pixels, 200}
            }} =
             conn(:get, "/_/size:300:200/rt:force/plain/images/cat.jpg") |> Native.parse()
  end

  test "reserves chained pipeline separator as its own parser error" do
    assert Native.parse(conn(:get, "/_/rs:fit:500:500/-/trim:10/plain/images/cat.jpg")) ==
             {:error, :unsupported_chained_pipeline}

    assert {:ok, %ProcessingRequest{resizing_type: :fill_down}} =
             conn(:get, "/_/rs:fill-down:300:200/plain/images/cat.jpg") |> Native.parse()
  end

  test "detects raw source extension before percent decoding" do
    assert {:ok,
            %ProcessingRequest{
              source_path: ["images", "cat@v1.jpg"],
              format: :webp
            }} = conn(:get, "/_/plain/images/cat%40v1.jpg@webp") |> Native.parse()
  end

  test "parses supported source extensions" do
    cases = [
      {"webp", :webp},
      {"avif", :avif},
      {"jpeg", :jpeg},
      {"jpg", :jpeg},
      {"png", :png},
      {"best", :best}
    ]

    for {extension, format} <- cases do
      assert {:ok,
              %ProcessingRequest{
                format: ^format
              }} = conn(:get, "/_/plain/images/cat.jpg@#{extension}") |> Native.parse()
    end
  end

  test "source extension takes precedence over processing format option" do
    assert {:ok,
            %ProcessingRequest{
              format: :png
            }} = conn(:get, "/_/f:webp/plain/images/cat.jpg@png") |> Native.parse()
  end

  test "dangling raw @ preserves explicit processing format" do
    assert {:ok,
            %ProcessingRequest{
              format: :webp
            }} = conn(:get, "/_/f:webp/plain/images/cat.jpg@") |> Native.parse()
  end

  test "dangling raw @ leaves output automatic when no explicit format exists" do
    assert {:ok,
            %ProcessingRequest{
              source_path: ["images", "cat.jpg"],
              format: nil
            }} = conn(:get, "/_/plain/images/cat.jpg@") |> Native.parse()
  end

  test "rejects empty plain source before extension" do
    assert Native.parse(conn(:get, "/_/plain/@webp")) ==
             {:error, {:missing_source_identifier, "plain"}}
  end

  test "rejects multiple raw @ source extension separators" do
    assert Native.parse(conn(:get, "/_/plain/images/cat.jpg@webp@png")) ==
             {:error, {:multiple_source_format_separators, "images/cat.jpg@webp@png"}}
  end

  test "rejects unknown source extensions as parser errors" do
    assert Native.parse(conn(:get, "/_/plain/images/cat.jpg@unknown")) ==
             {:error,
              {:invalid_format, "unknown", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
  end

  test "parses best source extension for planner rejection" do
    assert {:ok,
            %ProcessingRequest{
              format: :best
            }} = conn(:get, "/_/plain/images/cat.jpg@best") |> Native.parse()
  end
end
