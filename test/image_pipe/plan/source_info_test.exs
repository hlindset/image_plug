defmodule ImagePipe.Plan.SourceInfoTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.SourceInfo

  test "holds neutral source facts with byte_size optional" do
    info = %SourceInfo{format: :jpeg, width: 1200, height: 800, orientation: 1, byte_size: 12_345}
    assert info.format == :jpeg
    assert info.width == 1200
    assert info.height == 800
    assert info.orientation == 1
    assert info.byte_size == 12_345
  end

  test "byte_size defaults to nil" do
    info = %SourceInfo{format: :png, width: 10, height: 10, orientation: 1}
    assert info.byte_size == nil
  end

  defp dims_info(orientation),
    do: %SourceInfo{format: :jpeg, width: 4000, height: 3000, orientation: orientation}

  test "display_dimensions/1 keeps stored dims for orientations 1-4" do
    for o <- [1, 2, 3, 4] do
      assert SourceInfo.display_dimensions(dims_info(o)) == {4000, 3000}
    end
  end

  test "display_dimensions/1 swaps width/height for orientations 5-8" do
    for o <- [5, 6, 7, 8] do
      assert SourceInfo.display_dimensions(dims_info(o)) == {3000, 4000}
    end
  end
end
