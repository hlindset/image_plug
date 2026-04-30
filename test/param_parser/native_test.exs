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
              format: nil,
              output_extension_from_source: nil
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

  test "keeps legacy processing format options scoped before Task 3" do
    assert {:ok,
            %ProcessingRequest{
              format: :auto,
              output_extension_from_source: nil
            }} = conn(:get, "/_/format:auto/plain/images/cat.jpg") |> Native.parse()

    assert Native.parse(conn(:get, "/_/format:best/plain/images/cat.jpg")) ==
             {:error, {:invalid_format, "best", ["auto", "webp", "avif", "jpeg", "png"]}}
  end

  test "detects raw source extension before percent decoding" do
    assert {:ok,
            %ProcessingRequest{
              source_path: ["images", "cat@v1.jpg"],
              format: :webp,
              output_extension_from_source: :webp
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
                format: ^format,
                output_extension_from_source: ^format
              }} = conn(:get, "/_/plain/images/cat.jpg@#{extension}") |> Native.parse()
    end
  end

  test "dangling raw @ leaves output automatic when no explicit format exists" do
    assert {:ok,
            %ProcessingRequest{
              source_path: ["images", "cat.jpg"],
              format: nil,
              output_extension_from_source: nil
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
              format: :best,
              output_extension_from_source: :best
            }} = conn(:get, "/_/plain/images/cat.jpg@best") |> Native.parse()
  end
end
