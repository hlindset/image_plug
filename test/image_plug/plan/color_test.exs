defmodule ImagePlug.Plan.ColorTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Color
  alias ImagePlug.Plan.Operation

  test "constructs opaque sRGB color from integer channels" do
    assert {:ok,
            %Color{
              space: :srgb,
              channels: {255, 0, 16},
              alpha: {:ratio, 1, 1}
            }} = Color.rgb(255, 0, 16)
  end

  test "rejects non-byte RGB channels" do
    assert Color.rgb(-1, 0, 0) == {:error, {:invalid_color, [-1, 0, 0]}}
    assert Color.rgb(0, 256, 0) == {:error, {:invalid_color, [0, 256, 0]}}
    assert Color.rgb(0, 0, 1.5) == {:error, {:invalid_color, [0, 0, 1.5]}}
  end

  test "serializes deterministic cache key data without leaking Color structs" do
    assert {:ok, red} = Color.rgb(255, 0, 0)

    assert Color.key_data(red) == [
             space: :srgb,
             red: 255,
             green: 0,
             blue: 0,
             alpha: [unit: :ratio, numerator: 1, denominator: 1]
           ]

    refute inspect(Color.key_data(red)) =~ "Color.SRGB"
  end

  test "Operation exposes color constructors through the Plan facade" do
    assert Operation.color(1, 2, 3) == Color.rgb(1, 2, 3)
  end

  describe "boundary RGB values" do
    test "accepts minimum channel values (0, 0, 0)" do
      assert {:ok, %Color{channels: {0, 0, 0}}} = Color.rgb(0, 0, 0)
    end

    test "accepts maximum channel values (255, 255, 255)" do
      assert {:ok, %Color{channels: {255, 255, 255}}} = Color.rgb(255, 255, 255)
    end

    test "rejects channels just outside byte boundary" do
      assert {:error, {:invalid_color, [256, 0, 0]}} = Color.rgb(256, 0, 0)
      assert {:error, {:invalid_color, [0, 256, 0]}} = Color.rgb(0, 256, 0)
      assert {:error, {:invalid_color, [0, 0, 256]}} = Color.rgb(0, 0, 256)
      assert {:error, {:invalid_color, [-1, 0, 0]}} = Color.rgb(-1, 0, 0)
    end

    test "rejects nil, atom, and string channels" do
      assert {:error, {:invalid_color, [nil, 0, 0]}} = Color.rgb(nil, 0, 0)
      assert {:error, {:invalid_color, [:red, 0, 0]}} = Color.rgb(:red, 0, 0)
      assert {:error, {:invalid_color, ["255", 0, 0]}} = Color.rgb("255", 0, 0)
      assert {:error, {:invalid_color, [1.0, 0, 0]}} = Color.rgb(1.0, 0, 0)
    end
  end

  describe "valid?/1" do
    test "returns true for a well-formed sRGB Color struct" do
      assert {:ok, color} = Color.rgb(128, 64, 32)
      assert Color.valid?(color) == true
    end

    test "returns true for boundary sRGB colors" do
      assert {:ok, black} = Color.rgb(0, 0, 0)
      assert {:ok, white} = Color.rgb(255, 255, 255)
      assert Color.valid?(black) == true
      assert Color.valid?(white) == true
    end

    test "returns false for non-Color values" do
      refute Color.valid?(nil)
      refute Color.valid?(:red)
      refute Color.valid?({255, 0, 0})
      refute Color.valid?(%{space: :srgb, channels: {255, 0, 0}, alpha: {:ratio, 1, 1}})
    end

    test "returns false for malformed Color structs with out-of-range channels" do
      # Manually constructed to bypass constructor validation
      malformed = %Color{space: :srgb, channels: {300, 0, 0}, alpha: {:ratio, 1, 1}}
      refute Color.valid?(malformed)
    end

    test "returns false for Color structs with wrong space" do
      malformed = %Color{space: :cmyk, channels: {0, 0, 0}, alpha: {:ratio, 1, 1}}
      refute Color.valid?(malformed)
    end
  end

  describe "to_rgb_list/1" do
    test "extracts RGB channels as a list" do
      assert {:ok, color} = Color.rgb(10, 20, 30)
      assert Color.to_rgb_list(color) == [10, 20, 30]
    end

    test "extracts boundary values correctly" do
      assert {:ok, black} = Color.rgb(0, 0, 0)
      assert {:ok, white} = Color.rgb(255, 255, 255)
      assert Color.to_rgb_list(black) == [0, 0, 0]
      assert Color.to_rgb_list(white) == [255, 255, 255]
    end

    test "returns channels in RGB order" do
      assert {:ok, color} = Color.rgb(100, 150, 200)
      [r, g, b] = Color.to_rgb_list(color)
      assert r == 100
      assert g == 150
      assert b == 200
    end
  end

  describe "key_data/1" do
    test "includes all required sRGB fields" do
      assert {:ok, color} = Color.rgb(10, 20, 30)
      data = Color.key_data(color)
      assert Keyword.keys(data) == [:space, :red, :green, :blue, :alpha]
    end

    test "serializes each channel independently for cache discrimination" do
      assert {:ok, color_a} = Color.rgb(1, 2, 3)
      assert {:ok, color_b} = Color.rgb(3, 2, 1)
      refute Color.key_data(color_a) == Color.key_data(color_b)
    end

    test "produces identical key data for structurally equal colors" do
      assert {:ok, color_a} = Color.rgb(128, 64, 32)
      assert {:ok, color_b} = Color.rgb(128, 64, 32)
      assert Color.key_data(color_a) == Color.key_data(color_b)
    end
  end
end
