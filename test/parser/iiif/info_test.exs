defmodule ImagePipe.Parser.IIIF.InfoTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.IIIF.{Info, InfoRenderer}
  alias ImagePipe.Plan.{RenderContext, SourceInfo}

  @info %SourceInfo{format: :jpeg, width: 1000, height: 600, orientation: 1}
  @params %{
    id: "http://x/iiif/abc",
    level: "level2",
    offers: [],
    max_width: nil,
    max_height: nil,
    max_area: nil,
    formats: [:jpg, :png],
    qualities: [:default, :gray]
  }

  test "document has required IIIF 3.0 fields with display dims" do
    doc = Info.document(@info, @params)
    assert doc["@context"] == "http://iiif.io/api/image/3/context.json"
    assert doc["id"] == "http://x/iiif/abc"
    assert doc["type"] == "ImageService3"
    assert doc["protocol"] == "http://iiif.io/api/image"
    assert doc["profile"] == "level2"
    assert doc["width"] == 1000 and doc["height"] == 600
  end

  test "quarter-turn orientation swaps width/height in info" do
    doc =
      Info.document(
        %SourceInfo{format: :jpeg, width: 1000, height: 600, orientation: 6},
        @params
      )

    assert doc["width"] == 600 and doc["height"] == 1000
  end

  test "renderer returns application/json body" do
    {:ok, {"application/json", body}} =
      InfoRenderer.render(%RenderContext{info: @info}, @params, [])

    assert IO.iodata_to_binary(body) =~ "ImageService3"
  end
end
