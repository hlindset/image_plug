defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.AdaptiveResize do
  def material(%ImagePlug.Transform.AdaptiveResize{} = operation) do
    [
      op: :adaptive_resize,
      rule: rule_material(operation.rule)
    ]
  end

  defp rule_material(rule) do
    [
      mode: rule.mode,
      width: rule.width,
      height: rule.height,
      min_width: rule.min_width,
      min_height: rule.min_height,
      zoom_x: rule.zoom_x,
      zoom_y: rule.zoom_y,
      dpr: rule.dpr,
      effective_dpr: :runtime_resolved,
      enlarge: rule.enlarge
    ]
  end
end
