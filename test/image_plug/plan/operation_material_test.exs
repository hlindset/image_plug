defmodule ImagePlug.Plan.OperationMaterialTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Geometry.Dimension
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
