defmodule ImagePlug.Parser.Imgproxy.PathTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePlug.Parser.Imgproxy.Path

  test "extracts signature, signed path, and repaired path info" do
    conn = conn(:get, "/_/rs%3Afit%3A300/plain/local:/images/cat.jpg")

    assert {:ok, "_", "/rs:fit:300/plain/local:///images/cat.jpg", path_info} =
             Path.extract(conn)

    assert path_info == ["rs:fit:300", "plain", "local:", "", "", "images", "cat.jpg"]
  end

  test "extracts path under plug script name" do
    conn =
      conn(:get, "/img/_/plain/images/cat.jpg")
      |> Map.put(:script_name, ["img"])

    assert {:ok, "_", "/plain/images/cat.jpg", ["plain", "images", "cat.jpg"]} =
             Path.extract(conn)
  end

  test "splits option segments from plain source marker" do
    assert Path.split_source(["w:100", "plain", "images", "cat.jpg"]) ==
             {:ok, ["w:100"], ["images", "cat.jpg"]}
  end

  test "keeps raw encoded at-signs in source before parsing extension suffix" do
    assert Path.parse_plain_source(["images", "cat%40v1.jpg@webp"]) ==
             {:ok, ["images", "cat@v1.jpg"], :webp}
  end

  test "rejects malformed percent encoding without raising" do
    assert Path.parse_plain_source(["images", "cat%ZZ.jpg"]) ==
             {:error, {:invalid_percent_encoding, "cat%ZZ.jpg"}}
  end

  describe "extract errors" do
    test "rejects empty and signature-only paths" do
      assert Path.extract(conn(:get, "/")) == {:error, :missing_signature}
      assert Path.extract(conn(:get, "/_")) == {:error, :missing_signed_path}
    end

    test "rejects paths that start with an empty signature" do
      conn =
        conn(:get, "/")
        |> Map.put(:request_path, "//plain/images/cat.jpg")
        |> Map.put(:path_info, ["", "plain", "images", "cat.jpg"])

      assert Path.extract(conn) == {:error, :missing_signature}
    end

    test "strips multi-segment script_name prefixes before extracting" do
      conn =
        conn(:get, "/proxy/v1/_/plain/images/cat.jpg")
        |> Map.put(:script_name, ["proxy", "v1"])

      assert {:ok, "_", "/plain/images/cat.jpg", ["plain", "images", "cat.jpg"]} =
               Path.extract(conn)
    end

    test "treats a path equal to script_name as the mounted root" do
      conn =
        conn(:get, "/img")
        |> Map.put(:script_name, ["img"])
        |> Map.put(:request_path, "/img")

      assert Path.extract(conn) == {:error, :missing_signature}
    end
  end

  describe "path repair" do
    test "repairs lowercase percent-encoded option colons" do
      conn = conn(:get, "/_/w%3a300/plain/images/cat.jpg")

      assert {:ok, "_", signed_path, _path_info} = Path.extract(conn)
      assert signed_path == "/w:300/plain/images/cat.jpg"
    end

    test "repairs http plain URL scheme normalization" do
      conn = conn(:get, "/_/plain/http:/example.com/image.jpg")

      assert {:ok, "_", signed_path, _path_info} = Path.extract(conn)
      assert signed_path == "/plain/http://example.com/image.jpg"
    end
  end

  describe "split_source" do
    test "rejects paths without a plain source marker" do
      assert Path.split_source(["w:100", "h:200"]) == {:error, :missing_source_kind}
    end

    test "rejects paths where plain has no source segments" do
      assert Path.split_source(["w:100", "plain"]) ==
               {:error, {:missing_source_identifier, "plain"}}
    end

    test "splits empty options when plain is first" do
      assert Path.split_source(["plain", "images", "cat.jpg"]) ==
               {:ok, [], ["images", "cat.jpg"]}
    end

    test "stops at the first plain marker" do
      assert Path.split_source(["plain", "plain", "cat.jpg"]) ==
               {:ok, [], ["plain", "cat.jpg"]}
    end
  end

  describe "parse_plain_source" do
    test "parses known source format suffixes" do
      assert Path.parse_plain_source(["images", "cat.jpg@avif"]) ==
               {:ok, ["images", "cat.jpg"], :avif}

      assert Path.parse_plain_source(["images", "cat.jpg@jpg"]) ==
               {:ok, ["images", "cat.jpg"], :jpeg}
    end

    test "allows a trailing source format separator without an extension" do
      assert Path.parse_plain_source(["images", "cat.jpg@"]) ==
               {:ok, ["images", "cat.jpg"], nil}
    end

    test "rejects unknown source format suffixes" do
      assert Path.parse_plain_source(["images", "cat.jpg@gif"]) ==
               {:error, {:invalid_format, "gif", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
    end

    test "rejects empty source identifiers" do
      assert Path.parse_plain_source([""]) ==
               {:error, {:missing_source_identifier, "plain"}}

      assert Path.parse_plain_source(["@webp"]) ==
               {:error, {:missing_source_identifier, "plain"}}
    end

    test "rejects multiple source format separators" do
      assert Path.parse_plain_source(["cat.jpg@webp@png"]) ==
               {:error, {:multiple_source_format_separators, "cat.jpg@webp@png"}}
    end

    test "decodes percent-encoded source path segments" do
      assert Path.parse_plain_source(["images", "cat%20dog.jpg"]) ==
               {:ok, ["images", "cat dog.jpg"], nil}
    end
  end
end
