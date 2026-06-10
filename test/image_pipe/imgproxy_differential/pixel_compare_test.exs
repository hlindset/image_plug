defmodule ImagePipe.Test.ImgproxyDifferential.PixelCompareTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.ImgproxyDifferential.PixelCompare

  defp img(w, h, color), do: Image.new!(w, h, color: color)

  describe "dims/1" do
    test "returns width and height" do
      assert PixelCompare.dims(img(7, 3, :black)) == {7, 3}
    end
  end

  describe "same_dims?/2" do
    test "true for equal dims, false otherwise" do
      assert PixelCompare.same_dims?(img(4, 4, :black), img(4, 4, :white))
      refute PixelCompare.same_dims?(img(4, 4, :black), img(5, 4, :white))
    end
  end

  describe "outliers/3" do
    test "identical images have zero outliers" do
      a = img(16, 16, [10, 20, 30])
      assert PixelCompare.outliers(a, a, 0) == 0
    end

    test "a uniform per-channel offset below threshold is not an outlier" do
      a = img(16, 16, [10, 20, 30])
      b = img(16, 16, [12, 22, 32])
      assert PixelCompare.outliers(a, b, 2) == 0
      # 16x16 pixels x 3 bands; every band-byte exceeds Δ1 here.
      assert PixelCompare.outliers(a, b, 1) == 16 * 16 * 3
    end

    test "raises on mismatched dims" do
      assert_raise ArgumentError, fn ->
        PixelCompare.outliers(img(4, 4, :black), img(5, 4, :black), 0)
      end
    end
  end

  describe "region_mean_delta/3" do
    test "mean absolute per-channel delta over a region equals a uniform offset" do
      a = img(32, 32, [40, 40, 40])
      b = img(32, 32, [46, 46, 46])
      assert_in_delta PixelCompare.region_mean_delta(a, b, {8, 8, 16, 16}), 6.0, 0.001
    end
  end
end
