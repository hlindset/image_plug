defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Operation.AdaptiveResize do
  def material(%ImagePlug.Transform.Operation.AdaptiveResize{} = operation) do
    [
      op: :adaptive_resize,
      rule: ImagePlug.Transform.Geometry.DimensionRule.material(operation.rule)
    ]
  end
end
