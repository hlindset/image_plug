defmodule ImagePlug.Transform.GeometryTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Transform.Geometry

  describe "to_pixels/2" do
    test "returns tagged results for valid and invalid scale values" do
      assert Geometry.to_pixels(100, {:scale, 1, 2}) == {:ok, 50}
      assert Geometry.to_pixels(100, {:scale, 1, 0}) == {:error, :zero_scale_denominator}
    end
  end

  describe "to_pixels!/2" do
    test "raises a clear error for zero scale denominators" do
      assert_raise ArgumentError, "scale denominator must be non-zero", fn ->
        Geometry.to_pixels!(100, {:scale, 1, 0})
      end
    end
  end
end
