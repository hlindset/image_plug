defmodule ImagePlug.Plan.OperationMaterialTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Region
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Transform.Material

  test "resize material is canonical semantic intent" do
    assert {:ok, size} = size(width: 300, height: 200, dpr: 2.0)
    assert {:ok, guide} = Gravity.anchor(:center, :bottom)

    assert {:ok, fit} = Operation.resize_fit(size: size, enlargement: :allow)
    assert {:ok, cover} = Operation.resize_cover(size: size, enlargement: :deny, guide: guide)
    assert {:ok, stretch} = Operation.resize_stretch(size: size, enlargement: :allow)

    assert Material.material(fit) == [
             op: :resize_fit,
             size: size_material(300, 200, 2.0),
             enlargement: :allow
           ]

    assert Material.material(cover) == [
             op: :resize_cover,
             size: size_material(300, 200, 2.0),
             enlargement: :deny,
             guide: [type: :anchor, x: :center, y: :bottom, space: :current]
           ]

    assert Material.material(stretch) == [
             op: :resize_stretch,
             size: size_material(300, 200, 2.0),
             enlargement: :allow
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
             rule: :imgproxy_orientation_match_v1
           ]

    refute Keyword.has_key?(material, :selected_branch)
    refute Keyword.has_key?(material, :branch)
    refute Keyword.has_key?(material, :source_width)
    refute Keyword.has_key?(material, :source_height)
    refute inspect(material) =~ "source_width"
    refute inspect(material) =~ "source_height"
    refute inspect(material) =~ "derivation"
    refute inspect(material) =~ "selected_branch"
  end

  test "guided crop material contains explicit guide and no parser syntax" do
    assert {:ok, size} = size(width: 50, height: 50, dpr: 1.0)
    assert {:ok, guide} = Gravity.anchor(:center, :center)
    assert {:ok, operation} = Operation.crop_guided(size: size, guide: guide)

    material = Material.material(operation)

    assert material == [
             op: :crop_guided,
             size: size_material(50, 50, 1.0),
             guide: [type: :anchor, x: :center, y: :center, space: :current]
           ]

    refute inspect(material) =~ "imgproxy"
    refute inspect(material) =~ "gravity:"
  end

  test "source-space crop region material stays source-metadata-free" do
    assert {:ok, region} = region()
    assert {:ok, operation} = Operation.crop_region(region: region)

    assert Material.material(operation) == [
             op: :crop_region,
             region: [
               space: :source,
               x: [unit: :ratio, numerator: 1, denominator: 10],
               y: [unit: :ratio, numerator: 1, denominator: 10],
               width: [unit: :ratio, numerator: 1, denominator: 2],
               height: [unit: :ratio, numerator: 1, denominator: 2]
             ]
           ]
  end

  test "canvas material contains explicit placement and first-slice policies" do
    assert {:ok, size} = size(width: 320, height: 240, dpr: 1.0)
    assert {:ok, placement} = Gravity.anchor(:center, :center)

    assert {:ok, operation} =
             Operation.canvas(
               size: size,
               placement: placement,
               background: :white,
               overflow: :reject
             )

    assert Material.material(operation) == [
             op: :canvas,
             size: size_material(320, 240, 1.0),
             placement: [type: :anchor, x: :center, y: :center, space: :current],
             background: :white,
             overflow: :reject
           ]
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

  defp region do
    with {:ok, x} <- Dimension.ratio(1, 10),
         {:ok, y} <- Dimension.ratio(1, 10),
         {:ok, width} <- Dimension.ratio(1, 2),
         {:ok, height} <- Dimension.ratio(1, 2) do
      Region.new(x: x, y: y, width: width, height: height, space: :source)
    end
  end
end
