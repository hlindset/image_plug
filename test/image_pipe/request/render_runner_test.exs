defmodule ImagePipe.Request.RenderRunnerTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Request.RenderRunner

  @fixture "test/support/image_pipe/test/imgproxy_differential/sources/exif_2.jpg"

  test "build_source_info maps decoded facts + byte_size; orientation defaults to 1..8" do
    {:ok, image} = Image.open(@fixture)
    {w, h} = {Image.width(image), Image.height(image)}
    decoded = %{image: image, source_format: :jpeg, original_dims: {w, h}}

    info = RenderRunner.build_source_info(decoded, 4096)

    assert info.format == :jpeg
    assert info.width == w
    assert info.height == h
    assert info.orientation in 1..8
    assert info.byte_size == 4096
  end

  test "build_source_info uses nil byte_size as-is" do
    {:ok, image} = Image.open(@fixture)
    decoded = %{image: image, source_format: :png, original_dims: {3, 2}}
    info = RenderRunner.build_source_info(decoded, nil)
    assert info.byte_size == nil
    assert info.width == 3
    assert info.height == 2
  end
end
