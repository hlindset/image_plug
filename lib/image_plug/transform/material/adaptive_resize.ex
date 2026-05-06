defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.AdaptiveResize do
  def material(%ImagePlug.Transform.AdaptiveResize{} = operation) do
    [
      op: :adaptive_resize,
      rule: ImagePlug.Transform.Geometry.DimensionRule.material(operation.rule)
    ]
  end
end
