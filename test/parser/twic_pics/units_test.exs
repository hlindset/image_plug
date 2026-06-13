defmodule ImagePipe.Parser.TwicPics.UnitsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.Units

  describe "length/1" do
    test "bare numbers are pixels" do
      assert Units.length("250") == {:ok, {:px, 250}}
    end

    test "px is not a TwicPics length unit (only p and s)" do
      # TwicPics has no `px` unit — pixels are bare. A standalone `250px` token
      # is invalid as a length; the `px` mixing case (`10px150`) is handled at
      # the Size level by splitting on `x` first (see size/1 below).
      assert {:error, _} = Units.length("250px")
    end

    test "percent suffix" do
      assert Units.length("50p") == {:ok, {:percent, 50}}
      assert Units.length("4.5p") == {:ok, {:percent, 4.5}}
    end

    test "scale suffix" do
      assert Units.length("0.5s") == {:ok, {:scale, 0.5}}
    end

    test "rejects malformed and non-positive pixels" do
      assert {:error, _} = Units.length("abc")
      assert {:error, _} = Units.length("0")
      assert {:error, _} = Units.length("-3")
    end
  end

  describe "size/1 (resize/cover/contain/inside)" do
    test "WxH, single dim (auto), and dash-auto" do
      assert Units.size("250x100") == {:ok, {{:px, 250}, {:px, 100}}}
      assert Units.size("250") == {:ok, {{:px, 250}, :auto}}
      assert Units.size("-x100") == {:ok, {:auto, {:px, 100}}}
      assert Units.size("250x-") == {:ok, {{:px, 250}, :auto}}
    end

    test "mixed units: `10px150` is 10 percent by 150 pixels (split on x first)" do
      # Per the TwicPics docs, `10px150` is a Size mixing a percent width (`10p`)
      # with a pixel height (`150`) — NOT `10px` (there is no `px` unit).
      assert Units.size("10px150") == {:ok, {{:percent, 10}, {:px, 150}}}
      assert Units.size("250px") == {:ok, {{:percent, 250}, :auto}}
    end
  end

  describe "crop_size/1" do
    test "omitted dimension is the full axis (1s), not aspect auto" do
      assert Units.crop_size("320") == {:ok, {{:px, 320}, :full_axis}}
      assert Units.crop_size("320x-") == {:ok, {{:px, 320}, :full_axis}}
      assert Units.crop_size("-x240") == {:ok, {:full_axis, {:px, 240}}}
    end
  end

  describe "ratio/1" do
    test "integer ratios" do
      assert Units.ratio("16:9") == {:ok, {:ratio, 16, 9}}
      assert Units.ratio("2:4") == {:ok, {:ratio, 1, 2}}
    end

    test "decimal ratios reduce to an integer ratio (exact, no float rounding)" do
      assert Units.ratio("1.5:2") == {:ok, {:ratio, 3, 4}}
      assert Units.ratio("1.5:2.25") == {:ok, {:ratio, 2, 3}}
      assert Units.ratio(".5:2") == {:ok, {:ratio, 1, 4}}
      assert Units.ratio("1.05:2.1") == {:ok, {:ratio, 1, 2}}
    end

    test "rejects non-positive and malformed" do
      assert {:error, _} = Units.ratio("0:9")
      assert {:error, _} = Units.ratio("0.0:9")
      assert {:error, _} = Units.ratio("-1.5:2")
      assert {:error, _} = Units.ratio("1.5.2:2")
      assert {:error, _} = Units.ratio("1.5")
      assert {:error, _} = Units.ratio("a:2")
    end
  end

  describe "coordinates/1" do
    test "two lengths" do
      assert Units.coordinates("20x50") == {:ok, {{:px, 20}, {:px, 50}}}
    end
  end

  describe "anchor/1" do
    test "the eight anchors map to plan guides" do
      assert Units.anchor("top-left") == {:ok, {:anchor, :left, :top}}
      assert Units.anchor("top") == {:ok, {:anchor, :center, :top}}
      assert Units.anchor("bottom-right") == {:ok, {:anchor, :right, :bottom}}
      assert Units.anchor("left") == {:ok, {:anchor, :left, :center}}
    end

    test "center is not a valid anchor" do
      assert {:error, _} = Units.anchor("center")
    end
  end
end
