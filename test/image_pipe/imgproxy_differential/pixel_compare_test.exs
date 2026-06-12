defmodule ImagePipe.Test.ImgproxyDifferential.PixelCompareTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.ImgproxyDifferential.PixelCompare
  alias Vix.Vips.Operation

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

  describe "fraction_over/3" do
    test "fraction of band-bytes exceeding the threshold" do
      a = img(16, 16, [10, 20, 30])
      b = img(16, 16, [12, 22, 32])
      # every band-byte differs by exactly 2: none exceed Δ2, all exceed Δ1
      assert PixelCompare.fraction_over(a, b, 2) == 0.0
      assert PixelCompare.fraction_over(a, b, 1) == 1.0
    end

    test "identical images have zero fraction" do
      a = img(16, 16, [10, 20, 30])
      assert PixelCompare.fraction_over(a, a, 0) == 0.0
    end
  end

  describe "spatial_contrast/1" do
    test "a spatially uniform image is zero regardless of its colour" do
      assert PixelCompare.spatial_contrast(img(16, 16, [0, 0, 0])) == 0.0

      # The load-bearing property: a uniform [200,180,60] fill has a *band-byte*
      # range of 140 (the cross-channel gamut) but zero spatial variation, so it must
      # read as 0 — proving we measure per-band spatial range, not band-byte range.
      assert PixelCompare.spatial_contrast(img(16, 16, [200, 180, 60])) == 0.0
    end

    test "a hard black/white edge reads near the full 0..255 range" do
      black = img(8, 16, [0, 0, 0])
      white = img(8, 16, [255, 255, 255])
      {:ok, edge} = Operation.join(black, white, :VIPS_DIRECTION_HORIZONTAL)

      assert_in_delta PixelCompare.spatial_contrast(edge), 255.0, 0.5
    end

    test "normalizes 16-bit images onto the same 0..255 scale" do
      # 255 cast to u16 stays 255; scale by 257 to reach the true 16-bit max (65535).
      to_u16 = fn image, scale ->
        image |> Operation.linear!([scale], [0.0]) |> Image.cast!({:u, 16})
      end

      lo = img(8, 16, [0, 0, 0]) |> to_u16.(1.0)
      hi = img(8, 16, [255, 255, 255]) |> to_u16.(257.0)
      {:ok, edge} = Operation.join(lo, hi, :VIPS_DIRECTION_HORIZONTAL)

      # a full-range 16-bit edge (Δ65535) normalizes to ~255, not ~65535
      assert_in_delta PixelCompare.spatial_contrast(edge), 255.0, 0.5
    end
  end

  describe "diagnose/3" do
    test "identical images: comparable, zero max delta, empty histogram" do
      a = img(16, 16, [10, 20, 30])
      d = PixelCompare.diagnose(a, a)

      assert d.comparable
      assert d.dims == {{16, 16}, {16, 16}}
      assert d.bands == {3, 3}
      assert d.max_delta == 0
      assert d.over == %{2 => 0, 16 => 0, 32 => 0}
    end

    test "reports max delta and per-threshold band-byte counts" do
      a = img(16, 16, [10, 20, 30])
      b = img(16, 16, [30, 40, 50])
      d = PixelCompare.diagnose(a, b)

      # every band-byte differs by exactly 20
      assert d.max_delta == 20
      assert d.over == %{2 => 16 * 16 * 3, 16 => 16 * 16 * 3, 32 => 0}
    end

    test "honors a custom threshold list" do
      a = img(8, 8, [10, 10, 10])
      b = img(8, 8, [25, 25, 25])
      d = PixelCompare.diagnose(a, b, [10, 20])

      assert d.max_delta == 15
      assert d.over == %{10 => 8 * 8 * 3, 20 => 0}
    end

    test "band-layout mismatch: not comparable, bands reported, no delta math" do
      rgb = img(4, 4, [0, 0, 0])
      rgba = Image.add_alpha!(rgb, :opaque)
      assert Image.bands(rgba) == 4

      d = PixelCompare.diagnose(rgb, rgba)

      refute d.comparable
      assert d.bands == {3, 4}
      assert d.dims == {{4, 4}, {4, 4}}
      assert d.max_delta == nil
      assert d.over == %{}
    end

    test "dimension mismatch: not comparable, dims reported, no delta math" do
      d = PixelCompare.diagnose(img(4, 4, :black), img(5, 4, :black))

      refute d.comparable
      assert d.dims == {{4, 4}, {5, 4}}
      assert d.max_delta == nil
    end
  end
end
