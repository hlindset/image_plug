defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Operation.Resize do
  def material(%ImagePlug.Transform.Operation.Resize{} = operation) do
    [
      op: :resize,
      rule: ImagePlug.Transform.Geometry.DimensionRule.material(operation.rule)
    ]
  end
end
