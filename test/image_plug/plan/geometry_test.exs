defmodule ImagePlug.Plan.GeometryTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Region
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Transform.Material

  test "dimension material is explicit and source-fetch-free" do
    assert {:ok, auto} = Dimension.auto()
    assert {:ok, full_axis} = Dimension.full_axis()
    assert {:ok, pixels} = Dimension.pixels(100)
    assert {:ok, ratio} = Dimension.ratio(2, 4)

    assert Material.material(auto) == [unit: :auto]
    assert Material.material(full_axis) == [unit: :full_axis]
    assert Material.material(pixels) == [unit: :logical_px, value: 100]

    assert Material.material(ratio) == [
             unit: :ratio,
             numerator: 1,
             denominator: 2
           ]
  end

  test "dimension pixels reject zero and invalid ratio values" do
    assert Dimension.pixels(0) == {:error, {:invalid_dimension, :pixels, 0}}
    assert Dimension.pixels(-1) == {:error, {:invalid_dimension, :pixels, -1}}
    assert Dimension.ratio(0, 1) == {:error, {:invalid_dimension, :ratio, {0, 1}}}
    assert Dimension.ratio(1, 0) == {:error, {:invalid_dimension, :ratio, {1, 0}}}
  end

  test "size requires dimension values and positive DPR" do
    assert {:ok, dimension} = Dimension.pixels(100)
    assert {:ok, auto} = Dimension.auto()
    assert {:ok, size} = Size.new(width: dimension, height: auto, dpr: 2.0)

    assert Material.material(size) == [
             width: [unit: :logical_px, value: 100],
             height: [unit: :auto],
             dpr: 2.0
           ]

    assert Size.new(width: dimension, height: dimension, dpr: 0) ==
             {:error, {:invalid_size, [width: dimension, height: dimension, dpr: 0]}}

    assert Size.new(width: dimension, height: dimension, dpr: -1) ==
             {:error, {:invalid_size, [width: dimension, height: dimension, dpr: -1]}}

    assert Size.new(width: :pixels, height: dimension, dpr: 1.0) ==
             {:error, {:invalid_size, [width: :pixels, height: dimension, dpr: 1.0]}}
  end

  test "source-space crop region material stays source-metadata-free" do
    assert {:ok, x} = Dimension.ratio(1, 10)
    assert {:ok, y} = Dimension.ratio(1, 10)
    assert {:ok, width} = Dimension.ratio(1, 2)
    assert {:ok, height} = Dimension.ratio(1, 2)

    assert {:ok, region} =
             Region.new(x: x, y: y, width: width, height: height, space: :source)

    assert Material.material(region) == [
             space: :source,
             x: [unit: :ratio, numerator: 1, denominator: 10],
             y: [unit: :ratio, numerator: 1, denominator: 10],
             width: [unit: :ratio, numerator: 1, denominator: 2],
             height: [unit: :ratio, numerator: 1, denominator: 2]
           ]

    assert Region.new(x: x, y: y, width: width, height: height, space: :invalid) ==
             {:error,
              {:invalid_region, [x: x, y: y, width: width, height: height, space: :invalid]}}
  end

  test "gravity material includes explicit guide space" do
    assert {:ok, anchor} = Gravity.anchor(:center, :bottom)
    assert {:ok, focal_point} = Gravity.focal_point(1, 4, 3, 4)

    assert Material.material(anchor) == [
             type: :anchor,
             x: :center,
             y: :bottom,
             space: :current
           ]

    assert Material.material(focal_point) == [
             type: :focal_point,
             x: [unit: :ratio, numerator: 1, denominator: 4],
             y: [unit: :ratio, numerator: 3, denominator: 4],
             space: :current
           ]

    assert Gravity.anchor(:middle, :bottom) ==
             {:error, {:invalid_gravity, {:anchor, :middle, :bottom}}}

    assert Gravity.focal_point(0, 1, 3, 4) ==
             {:error, {:invalid_gravity, {:focal_point, 0, 1, 3, 4, :current}}}

    assert Gravity.focal_point(1, 4, 3, 4, :invalid) ==
             {:error, {:invalid_gravity, {:focal_point, 1, 4, 3, 4, :invalid}}}
  end
end
