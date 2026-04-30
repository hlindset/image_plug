defmodule ImagePlug.ImageMaterializerTest do
  use ExUnit.Case, async: true

  alias ImagePlug.ImageMaterializer

  test "materialize returns a memory-resident image with the same dimensions" do
    {:ok, image} = Image.new(32, 24, color: :white)

    assert {:ok, %Vix.Vips.Image{} = materialized} = ImageMaterializer.materialize(image)
    assert Image.width(materialized) == 32
    assert Image.height(materialized) == 24
  end
end
