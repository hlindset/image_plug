defmodule ImagePipe.Parser.IIIF.TilingTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.IIIF.Tiling

  test "Cantaloupe reference: 1500x1200, tile 512" do
    result = Tiling.tiles_and_sizes(1500, 1200, 512)

    assert result.scale_factors == [1, 2, 4, 8, 16]
    assert result.tile == %{width: 512, height: 512}
    # round (half-up for positive), smallest-first, full last.
    # 1500/16 = 93.75 -> 94 (floor would give 93 -> proves round).
    assert result.sizes == [
             %{width: 94, height: 75},
             %{width: 188, height: 150},
             %{width: 375, height: 300},
             %{width: 750, height: 600},
             %{width: 1500, height: 1200}
           ]
  end

  test "source smaller than tile in a dimension: tile clamps to source" do
    result = Tiling.tiles_and_sizes(300, 200, 512)

    # short side 200 -> 100, 50<64 at i=1 -> maxRF=1
    assert result.scale_factors == [1, 2]
    assert result.tile == %{width: 300, height: 200}
    assert result.sizes == [%{width: 150, height: 100}, %{width: 300, height: 200}]
  end

  test "tiny sources collapse to a single level" do
    assert Tiling.tiles_and_sizes(64, 64, 512) == %{
             scale_factors: [1],
             tile: %{width: 64, height: 64},
             sizes: [%{width: 64, height: 64}]
           }

    assert Tiling.tiles_and_sizes(1, 1, 512) == %{
             scale_factors: [1],
             tile: %{width: 1, height: 1},
             sizes: [%{width: 1, height: 1}]
           }
  end

  test "extreme aspect ratio: ladder bounded by the short side" do
    # short side 65 -> 32.5<64 at i=0 -> maxRF=0 -> single level
    result = Tiling.tiles_and_sizes(2000, 65, 512)
    assert result.scale_factors == [1]
    assert result.sizes == [%{width: 2000, height: 65}]
    assert result.tile == %{width: 512, height: 65}
  end
end
