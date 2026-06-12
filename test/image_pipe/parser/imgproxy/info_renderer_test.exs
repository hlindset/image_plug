defmodule ImagePipe.Parser.Imgproxy.InfoRendererTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.Imgproxy.InfoRenderer
  alias ImagePipe.Plan.RenderContext
  alias ImagePipe.Plan.SourceInfo

  defp render(info) do
    {:ok, {content_type, body}} = InfoRenderer.render(%RenderContext{info: info}, %{}, [])
    {content_type, JSON.decode!(IO.iodata_to_binary(body))}
  end

  test "requires only :header" do
    assert InfoRenderer.requires(%{}) == [:header]
  end

  test "renders the default field set for a jpeg" do
    info = %SourceInfo{format: :jpeg, width: 1200, height: 800, orientation: 1, byte_size: 9876}
    {content_type, json} = render(info)
    assert content_type == "application/json"
    assert json["format"] == "jpeg"
    assert json["mime_type"] == "image/jpeg"
    assert json["width"] == 1200
    assert json["height"] == 800
    assert json["orientation"] == 1
    assert json["size"] == 9876
  end

  test "reports imgproxy spellings for HEIC and JXL sources" do
    {_ct, heic} = render(%SourceInfo{format: :heif, width: 10, height: 10, orientation: 1})
    assert heic["format"] == "heic"
    assert heic["mime_type"] == "image/heif"

    {_ct, jxl} = render(%SourceInfo{format: :jpeg_xl, width: 10, height: 10, orientation: 1})
    assert jxl["format"] == "jxl"
    assert jxl["mime_type"] == "image/jxl"
  end

  test "swaps width/height for EXIF orientations 5-8" do
    info = %SourceInfo{format: :jpeg, width: 4000, height: 3000, orientation: 6}
    {_ct, json} = render(info)
    assert json["width"] == 3000
    assert json["height"] == 4000
  end

  test "omits size when byte_size is nil" do
    info = %SourceInfo{format: :png, width: 5, height: 5, orientation: 1, byte_size: nil}
    {_ct, json} = render(info)
    refute Map.has_key?(json, "size")
  end
end
