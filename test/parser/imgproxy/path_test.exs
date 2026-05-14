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

  describe "extract error cases" do
    test "returns missing_signature for empty root path" do
      conn = conn(:get, "/")
      assert Path.extract(conn) == {:error, :missing_signature}
    end

    test "returns missing_signed_path for signature-only path" do
      conn = conn(:get, "/_")
      assert Path.extract(conn) == {:error, :missing_signed_path}
    end

    test "returns missing_signature for path that begins with empty signature" do
      conn =
        conn(:get, "/")
        |> Map.put(:request_path, "//plain/images/cat.jpg")
        |> Map.put(:path_info, ["", "plain", "images", "cat.jpg"])

      assert Path.extract(conn) == {:error, :missing_signature}
    end

    test "strips multi-segment script_name prefix before extracting" do
      conn =
        conn(:get, "/proxy/v1/_/plain/images/cat.jpg")
        |> Map.put(:script_name, ["proxy", "v1"])

      assert {:ok, "_", "/plain/images/cat.jpg", ["plain", "images", "cat.jpg"]} =
               Path.extract(conn)
    end

    test "returns missing_signature when path equals script_name prefix" do
      conn =
        conn(:get, "/img")
        |> Map.put(:script_name, ["img"])
        |> Map.put(:request_path, "/img")

      assert Path.extract(conn) == {:error, :missing_signature}
    end
  end

  describe "extract path repair" do
    test "repairs percent-encoded option colon separators" do
      conn = conn(:get, "/_/w%3A300/plain/images/cat.jpg")
      assert {:ok, "_", signed_path, _path_info} = Path.extract(conn)
      assert signed_path =~ "w:300"
    end

    test "repairs uppercase percent-encoded colon separators" do
      conn = conn(:get, "/_/w%3a300/plain/images/cat.jpg")
      assert {:ok, "_", signed_path, _path_info} = Path.extract(conn)
      assert signed_path =~ "w:300"
    end

    test "repairs http plain URL scheme normalization" do
      conn = conn(:get, "/_/plain/http:/example.com/image.jpg")
      assert {:ok, "_", signed_path, _path_info} = Path.extract(conn)
      assert signed_path =~ "http://example.com"
    end

    test "repairs local plain URL to triple-slash form" do
      conn = conn(:get, "/_/plain/local:/images/cat.jpg")
      assert {:ok, "_", signed_path, path_info} = Path.extract(conn)
      assert signed_path =~ "local:///"
      assert "local:" in path_info
    end
  end

  describe "split_source" do
    test "returns error when no plain marker is found" do
      assert Path.split_source(["w:100", "h:200"]) == {:error, :missing_source_kind}
    end

    test "returns error when plain is the last segment with no source" do
      assert Path.split_source(["w:100", "plain"]) ==
               {:error, {:missing_source_identifier, "plain"}}
    end

    test "splits with empty options when plain is first" do
      assert Path.split_source(["plain", "images", "cat.jpg"]) ==
               {:ok, [], ["images", "cat.jpg"]}
    end

    test "splits multiple option segments before plain" do
      assert Path.split_source(["w:100", "h:200", "plain", "images", "cat.jpg"]) ==
               {:ok, ["w:100", "h:200"], ["images", "cat.jpg"]}
    end

    test "stops at first occurrence of plain when it appears in source path too" do
      assert {:ok, [], ["plain", "cat.jpg"]} =
               Path.split_source(["plain", "plain", "cat.jpg"])
    end
  end

  describe "parse_plain_source" do
    test "parses source with no extension" do
      assert Path.parse_plain_source(["images", "cat.jpg"]) ==
               {:ok, ["images", "cat.jpg"], nil}
    end

    test "parses source with known extension" do
      assert Path.parse_plain_source(["images", "cat.jpg@webp"]) ==
               {:ok, ["images", "cat.jpg"], :webp}

      assert Path.parse_plain_source(["images", "cat.jpg@avif"]) ==
               {:ok, ["images", "cat.jpg"], :avif}

      assert Path.parse_plain_source(["images", "cat.jpg@jpeg"]) ==
               {:ok, ["images", "cat.jpg"], :jpeg}

      assert Path.parse_plain_source(["images", "cat.jpg@jpg"]) ==
               {:ok, ["images", "cat.jpg"], :jpeg}

      assert Path.parse_plain_source(["images", "cat.jpg@png"]) ==
               {:ok, ["images", "cat.jpg"], :png}
    end

    test "parses source with trailing @ and no extension" do
      assert Path.parse_plain_source(["images", "cat.jpg@"]) ==
               {:ok, ["images", "cat.jpg"], nil}
    end

    test "rejects unknown extension" do
      assert Path.parse_plain_source(["images", "cat.jpg@gif"]) ==
               {:error,
                {:invalid_format, "gif", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
    end

    test "rejects empty source before extension" do
      assert Path.parse_plain_source(["@webp"]) ==
               {:error, {:missing_source_identifier, "plain"}}
    end

    test "rejects completely empty source" do
      assert Path.parse_plain_source([""]) ==
               {:error, {:missing_source_identifier, "plain"}}
    end

    test "rejects multiple @ separators" do
      assert Path.parse_plain_source(["cat.jpg@webp@png"]) ==
               {:error, {:multiple_source_format_separators, "cat.jpg@webp@png"}}
    end

    test "decodes percent-encoded characters in source path segments" do
      assert Path.parse_plain_source(["images", "cat%20dog.jpg"]) ==
               {:ok, ["images", "cat dog.jpg"], nil}
    end

    test "handles multi-segment source paths" do
      assert Path.parse_plain_source(["a", "b", "c", "image.jpg@png"]) ==
               {:ok, ["a", "b", "c", "image.jpg"], :png}
    end
  end
end
