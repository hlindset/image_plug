defmodule ImagePlug.Plan.OperationKeyDataTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Operation
  alias ImagePlug.Transform.KeyData
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Rotate

  describe "tagged geometry data" do
    test "returns key data for symbolic dimensions" do
      assert KeyData.data(:auto) == [unit: :auto]
      assert KeyData.data(:full_axis) == [unit: :full_axis]
    end

    test "returns key data for logical pixel dimensions" do
      assert KeyData.data({:px, 300}) == [unit: :logical_px, value: 300]
    end

    test "canonicalizes ratio dimensions" do
      assert KeyData.data({:ratio, 6, 8}) == [unit: :ratio, numerator: 3, denominator: 4]
      assert KeyData.data({:ratio, 0, 10}) == [unit: :ratio, numerator: 0, denominator: 1]
    end
  end

  describe "DPR data" do
    test "canonicalizes equivalent DPR ones" do
      expected = [unit: :ratio, numerator: 1, denominator: 1]

      for dpr <- [1, 1.0, "1.00"] do
        assert {:ok, operation} = Operation.resize(:fit, {:px, 300}, :auto, dpr: dpr)
        assert KeyData.data(operation)[:dpr] == expected
      end
    end

    test "canonicalizes floats through fixed decimal precision" do
      assert {:ok, operation} = Operation.resize(:fit, {:px, 300}, :auto, dpr: 1.3324232)

      assert KeyData.data(operation)[:dpr] == [
               unit: :ratio,
               numerator: 1_665_529,
               denominator: 1_250_000
             ]
    end

    test "parses decimal strings exactly" do
      assert {:ok, seven_places} =
               Operation.resize(:fit, {:px, 300}, :auto, dpr: "1.3324232")

      assert KeyData.data(seven_places)[:dpr] == [
               unit: :ratio,
               numerator: 1_665_529,
               denominator: 1_250_000
             ]

      assert {:ok, eight_places} =
               Operation.resize(:fit, {:px, 300}, :auto, dpr: "1.33242321")

      assert KeyData.data(eight_places)[:dpr] == [
               unit: :ratio,
               numerator: 133_242_321,
               denominator: 100_000_000
             ]
    end
  end

  describe "resize operation data" do
    test "returns key data for unresolved resize auto semantic intent" do
      assert {:ok, operation} =
               Operation.resize(:auto, {:px, 300}, {:px, 200},
                 dpr: 2.0,
                 x_offset: {:pixels, 8.0},
                 y_offset: {:scale, -0.25}
               )

      data = KeyData.data(operation)

      assert data == [
               op: :resize,
               mode: :auto,
               width: [unit: :logical_px, value: 300],
               height: [unit: :logical_px, value: 200],
               dpr: [unit: :ratio, numerator: 2, denominator: 1],
               enlargement: :deny,
               guide: :center,
               x_offset: {:pixels, 8.0},
               y_offset: {:scale, -0.25},
               min_width: nil,
               min_height: nil,
               zoom_x: 1.0,
               zoom_y: 1.0,
               rule: :imgproxy_orientation_match_v1
             ]

      refute Keyword.has_key?(data, :selected_branch)
      refute Keyword.has_key?(data, :branch)
      refute inspect(data) =~ "resize_fit"
      refute inspect(data) =~ "resize_cover"
    end

    test "canonicalizes equivalent DPR values through operation key data" do
      expected_dpr = [unit: :ratio, numerator: 1, denominator: 1]

      for dpr <- [1, 1.0, "1.00"] do
        assert {:ok, operation} = Operation.resize(:fit, {:px, 300}, :auto, dpr: dpr)
        assert KeyData.data(operation)[:dpr] == expected_dpr
      end
    end
  end

  describe "crop operation data" do
    test "returns key data for guided crop semantic intent" do
      assert {:ok, operation} =
               Operation.crop_guided(
                 {:px, 300},
                 :full_axis,
                 {:focal, {:ratio, 1, 3}, {:ratio, 2, 3}},
                 x_offset: {:pixels, 4},
                 y_offset: {:scale, 0.25}
               )

      assert KeyData.data(operation) == [
               op: :crop_guided,
               width: [unit: :logical_px, value: 300],
               height: [unit: :full_axis],
               guide: [
                 type: :focal,
                 x: [unit: :ratio, numerator: 1, denominator: 3],
                 y: [unit: :ratio, numerator: 2, denominator: 3]
               ],
               x_offset: {:pixels, 4},
               y_offset: {:scale, 0.25}
             ]
    end

    test "returns key data for crop region without coordinate-space fields" do
      assert {:ok, operation} =
               Operation.crop_region({:px, 0}, {:ratio, 0, 1}, {:ratio, 1, 2}, {:px, 100})

      data = KeyData.data(operation)

      assert data == [
               op: :crop_region,
               x: [unit: :logical_px, value: 0],
               y: [unit: :ratio, numerator: 0, denominator: 1],
               width: [unit: :ratio, numerator: 1, denominator: 2],
               height: [unit: :logical_px, value: 100]
             ]

      refute Keyword.has_key?(data, :space)
      refute Keyword.has_key?(data, :coordinate_space)
    end
  end

  describe "canvas operation data" do
    test "returns key data for canvas semantic intent" do
      assert {:ok, operation} =
               Operation.canvas(
                 {:ratio, 16, 9},
                 {:ratio, 1, 1},
                 {:focal, {:ratio, 1, 3}, {:ratio, 2, 3}},
                 x_offset: 5.0,
                 y_offset: -3.0
               )

      assert KeyData.data(operation) == [
               op: :canvas,
               width: [unit: :ratio, numerator: 16, denominator: 9],
               height: [unit: :ratio, numerator: 1, denominator: 1],
               placement: [
                 type: :focal,
                 x: [unit: :ratio, numerator: 1, denominator: 3],
                 y: [unit: :ratio, numerator: 2, denominator: 3]
               ],
               fill: :transparent,
               overflow: :reject,
               x_offset: 5.0,
               y_offset: -3.0
             ]
    end
  end

  describe "orientation primitive data" do
    test "returns key data for allowed orientation primitives" do
      assert KeyData.data(%AutoOrient{}) == [op: :auto_orient]
      assert KeyData.data(%Rotate{angle: 270}) == [op: :rotate, angle: 270]
      assert KeyData.data(%Flip{axis: :both}) == [op: :flip, axis: :both]
    end
  end

  describe "padding operation data" do
    test "returns full key data for transparent padding with explicit pixel ratio" do
      assert {:ok, padding} =
               Operation.padding({:px, 10}, {:px, 20}, {:px, 30}, {:px, 40},
                 pixel_ratio: {:ratio, 3, 2}
               )

      assert KeyData.data(padding) == [
               op: :padding,
               top: [unit: :logical_px, value: 10],
               right: [unit: :logical_px, value: 20],
               bottom: [unit: :logical_px, value: 30],
               left: [unit: :logical_px, value: 40],
               pixel_ratio: [unit: :ratio, numerator: 3, denominator: 2],
               fill: :transparent
             ]
    end

    test "returns key data for padding with solid fill color" do
      assert {:ok, blue} = Operation.color(0, 0, 255)
      assert {:ok, padding} = Operation.padding({:px, 5}, {:px, 0}, {:px, 0}, {:px, 0},
               fill: {:solid, blue}
             )

      data = KeyData.data(padding)
      assert data[:fill] == [
               type: :solid,
               color: [
                 space: :srgb,
                 red: 0,
                 green: 0,
                 blue: 255,
                 alpha: [unit: :ratio, numerator: 1, denominator: 1]
               ]
             ]
    end

    test "returns key data for padding with effective resize pixel ratio" do
      assert {:ok, padding} =
               Operation.padding({:px, 10}, {:px, 0}, {:px, 0}, {:px, 0},
                 pixel_ratio: {:effective, {:ratio, 2, 1}, :resize}
               )

      assert KeyData.data(padding)[:pixel_ratio] == [
               unit: :effective_resize_pixel_ratio,
               fallback: [unit: :ratio, numerator: 2, denominator: 1],
               mode: :resize
             ]
    end

    test "returns key data for padding with canvas-preserving effective pixel ratio" do
      assert {:ok, padding} =
               Operation.padding({:px, 10}, {:px, 0}, {:px, 0}, {:px, 0},
                 pixel_ratio: {:effective, {:ratio, 1, 2}, :canvas_preserving}
               )

      assert KeyData.data(padding)[:pixel_ratio] == [
               unit: :effective_resize_pixel_ratio,
               fallback: [unit: :ratio, numerator: 1, denominator: 2],
               mode: :canvas_preserving
             ]
    end

    test "canonicalizes ratio denominators in pixel_ratio" do
      assert {:ok, padding} =
               Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 0},
                 pixel_ratio: {:ratio, 4, 6}
               )

      # 4/6 reduces to 2/3
      assert KeyData.data(padding)[:pixel_ratio] == [
               unit: :ratio,
               numerator: 2,
               denominator: 3
             ]
    end

    test "side key data includes unit and value tags" do
      assert {:ok, padding} =
               Operation.padding({:px, 7}, {:px, 0}, {:px, 0}, {:px, 3})

      data = KeyData.data(padding)
      assert data[:top] == [unit: :logical_px, value: 7]
      assert data[:right] == [unit: :logical_px, value: 0]
      assert data[:bottom] == [unit: :logical_px, value: 0]
      assert data[:left] == [unit: :logical_px, value: 3]
    end
  end

  describe "flatten background operation data" do
    test "returns key data with canonical color fields" do
      assert {:ok, red} = Operation.color(255, 0, 0)
      assert {:ok, flatten} = Operation.flatten_background(red)

      assert KeyData.data(flatten) == [
               op: :flatten_background,
               color: [
                 space: :srgb,
                 red: 255,
                 green: 0,
                 blue: 0,
                 alpha: [unit: :ratio, numerator: 1, denominator: 1]
               ]
             ]
    end

    test "discriminates between different background colors in key data" do
      assert {:ok, red} = Operation.color(255, 0, 0)
      assert {:ok, blue} = Operation.color(0, 0, 255)
      assert {:ok, flatten_red} = Operation.flatten_background(red)
      assert {:ok, flatten_blue} = Operation.flatten_background(blue)

      refute KeyData.data(flatten_red) == KeyData.data(flatten_blue)
    end

    test "key data does not include third-party Color struct references" do
      assert {:ok, green} = Operation.color(0, 128, 0)
      assert {:ok, flatten} = Operation.flatten_background(green)

      serialized = inspect(KeyData.data(flatten))
      refute serialized =~ "Color.SRGB"
      refute serialized =~ "%Color"
    end
  end

  describe "canvas fill key data" do
    test "transparent fill serializes as atom" do
      assert {:ok, canvas} = Operation.canvas({:px, 100}, {:px, 100}, :center)
      assert KeyData.data(canvas)[:fill] == :transparent
    end

    test "solid fill serializes with nested color key data" do
      assert {:ok, red} = Operation.color(255, 0, 0)
      assert {:ok, canvas} = Operation.canvas({:px, 100}, {:px, 100}, :center, fill: {:solid, red})

      assert KeyData.data(canvas)[:fill] == [
               type: :solid,
               color: [
                 space: :srgb,
                 red: 255,
                 green: 0,
                 blue: 0,
                 alpha: [unit: :ratio, numerator: 1, denominator: 1]
               ]
             ]
    end
  end
end
