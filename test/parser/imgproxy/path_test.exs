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
end
