defmodule ImagePlug.Plan.OperationMaterialTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Transform.Material
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Rotate

  test "resize material is canonical semantic intent" do
    assert {:ok, size} = size(width: 300, height: 200, dpr: 2.0)
    assert {:ok, guide} = Gravity.anchor(:center, :bottom)

    assert {:ok, fit} = Operation.resize_fit(size: size, enlargement: :allow)
    assert {:ok, cover} = Operation.resize_cover(size: size, enlargement: :deny, guide: guide)
    assert {:ok, stretch} = Operation.resize_stretch(size: size, enlargement: :allow)

    assert Material.material(fit) == [
             op: :resize_fit,
             size: size_material(300, 200, 2.0),
             enlargement: :allow,
             min_width: nil,
             min_height: nil,
             zoom_x: 1.0,
             zoom_y: 1.0
           ]

    assert Material.material(cover) == [
             op: :resize_cover,
             size: size_material(300, 200, 2.0),
             enlargement: :deny,
             guide: [type: :anchor, x: :center, y: :bottom, space: :current],
             min_width: nil,
             min_height: nil,
             zoom_x: 1.0,
             zoom_y: 1.0,
             x_offset: {:pixels, 0.0},
             y_offset: {:pixels, 0.0}
           ]

    assert Material.material(stretch) == [
             op: :resize_stretch,
             size: size_material(300, 200, 2.0),
             enlargement: :allow,
             min_width: nil,
             min_height: nil,
             zoom_x: 1.0,
             zoom_y: 1.0
           ]
  end

  test "resize auto material is unresolved semantic intent" do
    assert {:ok, size} = size(width: 300, height: 200, dpr: 2.0)
    assert {:ok, operation} = Operation.resize_auto(size: size, enlargement: :deny)

    material = Material.material(operation)

    assert material == [
             op: :resize_auto,
             size: size_material(300, 200, 2.0),
             enlargement: :deny,
             guide: [type: :anchor, x: :center, y: :center, space: :current],
             min_width: nil,
             min_height: nil,
             zoom_x: 1.0,
             zoom_y: 1.0,
             x_offset: {:pixels, 0.0},
             y_offset: {:pixels, 0.0},
             rule: :imgproxy_orientation_match_v1
           ]

    refute Keyword.has_key?(material, :selected_branch)
    refute Keyword.has_key?(material, :branch)
    refute Keyword.has_key?(material, :source_width)
    refute Keyword.has_key?(material, :source_height)
    refute inspect(material) =~ "source_width"
    refute inspect(material) =~ "source_height"
    refute inspect(material) =~ "selected_branch"
  end

  test "guided crop material contains explicit guide and no parser syntax" do
    assert {:ok, operation} = Operation.crop_guided({:px, 50}, {:px, 50}, :center)

    material = Material.material(operation)

    assert material == [
             op: :crop_guided,
             width: [unit: :logical_px, value: 50],
             height: [unit: :logical_px, value: 50],
             guide: :center,
             x_offset: {:pixels, 0.0},
             y_offset: {:pixels, 0.0}
           ]

    refute inspect(material) =~ "imgproxy"
    refute inspect(material) =~ "gravity:"
  end

  test "crop region material stays source-metadata-free" do
    assert {:ok, operation} =
             Operation.crop_region(
               {:ratio, 1, 10},
               {:ratio, 1, 10},
               {:ratio, 1, 2},
               {:ratio, 1, 2}
             )

    assert Material.material(operation) == [
             op: :crop_region,
             x: [unit: :ratio, numerator: 1, denominator: 10],
             y: [unit: :ratio, numerator: 1, denominator: 10],
             width: [unit: :ratio, numerator: 1, denominator: 2],
             height: [unit: :ratio, numerator: 1, denominator: 2]
           ]
  end

  test "canvas material contains explicit placement and first-slice policies" do
    assert {:ok, operation} =
             Operation.canvas({:px, 320}, {:px, 240}, :center)

    assert Material.material(operation) == [
             op: :canvas,
             width: [unit: :logical_px, value: 320],
             height: [unit: :logical_px, value: 240],
             placement: :center,
             background: :white,
             overflow: :reject,
             x_offset: 0.0,
             y_offset: 0.0
           ]
  end

  test "orientation material is source-fetch-free semantic intent" do
    auto_orient = %AutoOrient{}
    rotate = %Rotate{angle: 270}
    flip = %Flip{axis: :both}

    assert Material.material(auto_orient) == [op: :auto_orient]
    assert Material.material(rotate) == [op: :rotate, angle: 270]
    assert Material.material(flip) == [op: :flip, axis: :both]
  end

  defp size(width: width, height: height, dpr: dpr) do
    with {:ok, width} <- Dimension.pixels(width),
         {:ok, height} <- Dimension.pixels(height) do
      Size.new(width: width, height: height, dpr: dpr)
    end
  end

  defp size_material(width, height, dpr) do
    [
      width: [unit: :logical_px, value: width],
      height: [unit: :logical_px, value: height],
      dpr: dpr
    ]
  end
end
