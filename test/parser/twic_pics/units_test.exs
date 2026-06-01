defmodule ImagePipe.Parser.TwicPics.UnitsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.Units

  describe "length/1" do
    test "bare and px numbers are pixels" do
      assert Units.length("250") == {:ok, {:px, 250}}
      assert Units.length("250px") == {:ok, {:px, 250}}
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
  end

  describe "crop_size/1" do
    test "omitted dimension is the full axis (1s), not aspect auto" do
      assert Units.crop_size("320") == {:ok, {{:px, 320}, :full_axis}}
      assert Units.crop_size("320x-") == {:ok, {{:px, 320}, :full_axis}}
      assert Units.crop_size("-x240") == {:ok, {:full_axis, {:px, 240}}}
    end
  end

  describe "ratio/1" do
    test "two positive numbers" do
      assert Units.ratio("16:9") == {:ok, {:ratio, 16, 9}}
    end

    test "rejects non-positive" do
      assert {:error, _} = Units.ratio("0:9")
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
