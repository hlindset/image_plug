defmodule ImagePlug.Transform.Operation.CropCoordinateMapperTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Transform.Geometry.CropCoordinateMapper

  test "maps center crop without orientation exactly" do
    assert {:ok, mapped} =
             CropCoordinateMapper.map(
               source_width: 400,
               source_height: 300,
               crop_width: {:pixels, 100},
               crop_height: {:pixels, 50},
               gravity: {:anchor, :center, :center},
               x_offset: 0.0,
               y_offset: 0.0,
               orientation: %{auto_orient: false, rotate: 0, flip: :none}
             )

    assert %{left: 150, top: 126, width: 100, height: 50} = mapped
  end

  test "matches imgproxy center rounding for odd crop slack" do
    assert {:ok, mapped} =
             CropCoordinateMapper.map(
               source_width: 401,
               source_height: 300,
               crop_width: {:pixels, 100},
               crop_height: {:pixels, 100},
               gravity: {:anchor, :center, :center},
               x_offset: 0.0,
               y_offset: 0.0,
               orientation: %{auto_orient: false, rotate: 0, flip: :none}
             )

    assert %{left: 151, top: 100, width: 100, height: 100} = mapped
  end

  test "scales absolute offsets by an explicit offset scale" do
    assert {:ok, mapped} =
             CropCoordinateMapper.map(
               source_width: 800,
               source_height: 800,
               crop_width: {:pixels, 500},
               crop_height: {:pixels, 500},
               gravity: {:anchor, :right, :center},
               x_offset: {:pixels, -10},
               y_offset: 0.0,
               offset_scale: 1.6,
               orientation: %{auto_orient: false, rotate: 0, flip: :none}
             )

    assert mapped.left == 284
  end

  test "maps center crop through rotate 90 exactly" do
    assert {:ok, mapped} =
             CropCoordinateMapper.map(
               source_width: 400,
               source_height: 300,
               crop_width: {:pixels, 100},
               crop_height: {:pixels, 50},
               gravity: {:anchor, :center, :center},
               x_offset: 0.0,
               y_offset: 0.0,
               orientation: %{auto_orient: false, rotate: 90, flip: :none}
             )

    assert %{left: 176, top: 100, width: 50, height: 100} = mapped
  end

  test "maps center crop through rotate 180 exactly" do
    assert {:ok, mapped} =
             CropCoordinateMapper.map(
               source_width: 400,
               source_height: 300,
               crop_width: {:pixels, 100},
               crop_height: {:pixels, 50},
               gravity: {:anchor, :center, :center},
               x_offset: 0.0,
               y_offset: 0.0,
               orientation: %{auto_orient: false, rotate: 180, flip: :none}
             )

    assert %{left: 150, top: 124, width: 100, height: 50} = mapped
  end

  test "maps center crop through rotate 270 exactly" do
    assert {:ok, mapped} =
             CropCoordinateMapper.map(
               source_width: 400,
               source_height: 300,
               crop_width: {:pixels, 100},
               crop_height: {:pixels, 50},
               gravity: {:anchor, :center, :center},
               x_offset: 0.0,
               y_offset: 0.0,
               orientation: %{auto_orient: false, rotate: 270, flip: :none}
             )

    assert %{left: 174, top: 100, width: 50, height: 100} = mapped
  end

  test "horizontal flip mirrors anchor and absolute offset" do
    assert {:ok, left} =
             CropCoordinateMapper.map(
               source_width: 400,
               source_height: 300,
               crop_width: {:pixels, 100},
               crop_height: {:pixels, 100},
               gravity: {:anchor, :left, :center},
               x_offset: 10.0,
               y_offset: 0.0,
               orientation: %{auto_orient: false, rotate: 0, flip: :horizontal}
             )

    assert {:ok, right} =
             CropCoordinateMapper.map(
               source_width: 400,
               source_height: 300,
               crop_width: {:pixels, 100},
               crop_height: {:pixels, 100},
               gravity: {:anchor, :right, :center},
               x_offset: -10.0,
               y_offset: 0.0,
               orientation: %{auto_orient: false, rotate: 0, flip: :none}
             )

    assert left.left == right.left
  end

  test "auto crop dimensions expand to oriented source bounds" do
    assert {:ok, mapped} =
             CropCoordinateMapper.map(
               source_width: 400,
               source_height: 300,
               crop_width: :auto,
               crop_height: {:pixels, 200},
               gravity: {:anchor, :center, :center},
               x_offset: 0.0,
               y_offset: 0.0,
               orientation: %{auto_orient: false, rotate: 0, flip: :none}
             )

    assert mapped.width == 400
    assert mapped.height == 200
  end

  test "rejects auto-orient crop mapping without resolved orientation metadata" do
    assert CropCoordinateMapper.map(
             source_width: 400,
             source_height: 300,
             crop_width: {:pixels, 100},
             crop_height: {:pixels, 50},
             gravity: {:anchor, :center, :center},
             x_offset: 0.0,
             y_offset: 0.0,
             orientation: %{auto_orient: true, rotate: 0, flip: :none}
           ) == {:error, {:unsupported_crop_orientation, :auto_orient}}
  end
end
