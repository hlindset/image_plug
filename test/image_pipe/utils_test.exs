defmodule ImagePipe.Transform.GeometryTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Geometry

  describe "to_pixels/2" do
    test "resolves supported internal length units to pixels" do
      assert Geometry.to_pixels(100, {:scale, 1, 2}) == 50
      assert Geometry.to_pixels(100, {:percent, 25}) == 25
      assert Geometry.to_pixels(100, {:pixels, 12}) == 12
    end
  end
end
