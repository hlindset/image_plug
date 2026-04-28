defmodule ImagePlug.UtilsTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Utils

  describe "to_pixels/2" do
    test "raises a clear error for zero scale denominators" do
      assert_raise ArgumentError, "scale denominator must be non-zero", fn ->
        Utils.to_pixels(100, {:scale, 1, 0})
      end
    end
  end
end
