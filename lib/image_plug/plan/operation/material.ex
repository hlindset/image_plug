defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Geometry.Dimension do
  def material(%ImagePlug.Plan.Geometry.Dimension{unit: :auto}), do: [unit: :auto]
  def material(%ImagePlug.Plan.Geometry.Dimension{unit: :full_axis}), do: [unit: :full_axis]

  def material(%ImagePlug.Plan.Geometry.Dimension{unit: :logical_px, value: value}) do
    [unit: :logical_px, value: value]
  end

  def material(%ImagePlug.Plan.Geometry.Dimension{
        unit: :ratio,
        numerator: numerator,
        denominator: denominator
      }) do
    [unit: :ratio, numerator: numerator, denominator: denominator]
  end
end

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Geometry.Size do
  def material(%ImagePlug.Plan.Geometry.Size{} = size) do
    [
      width: ImagePlug.Transform.Material.material(size.width),
      height: ImagePlug.Transform.Material.material(size.height),
      dpr: size.dpr
    ]
  end
end

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Geometry.Region do
  def material(%ImagePlug.Plan.Geometry.Region{} = region) do
    [
      space: region.space,
      x: ImagePlug.Transform.Material.material(region.x),
      y: ImagePlug.Transform.Material.material(region.y),
      width: ImagePlug.Transform.Material.material(region.width),
      height: ImagePlug.Transform.Material.material(region.height)
    ]
  end
end

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Guide.Gravity do
  def material(%ImagePlug.Plan.Guide.Gravity{type: :anchor} = gravity) do
    [
      type: :anchor,
      x: gravity.x,
      y: gravity.y,
      space: gravity.space
    ]
  end

  def material(%ImagePlug.Plan.Guide.Gravity{type: :focal_point} = gravity) do
    [
      type: :focal_point,
      x: ImagePlug.Transform.Material.material(gravity.x),
      y: ImagePlug.Transform.Material.material(gravity.y),
      space: gravity.space
    ]
  end
end
