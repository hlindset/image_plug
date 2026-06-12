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
end
