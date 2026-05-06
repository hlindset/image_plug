defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Resize do
  def material(%ImagePlug.Transform.Resize{} = operation) do
    [
      op: :resize,
      rule: ImagePlug.Transform.Geometry.DimensionRule.material(operation.rule)
    ]
  end
end
