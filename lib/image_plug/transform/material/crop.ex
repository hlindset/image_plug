defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Crop do
  def material(%ImagePlug.Transform.Crop{crop_from: :gravity} = operation) do
    [
      op: :crop,
      width: operation.width,
      height: operation.height,
      crop_from: operation.crop_from,
      gravity: operation.gravity,
      x_offset: operation.x_offset,
      y_offset: operation.y_offset,
      orientation: orientation_material(operation.orientation)
    ]
    |> maybe_put_target_rule(operation.target_rule)
  end

  def material(%ImagePlug.Transform.Crop{} = operation) do
    [
      op: :crop,
      width: operation.width,
      height: operation.height,
      crop_from: operation.crop_from
    ]
  end

  defp orientation_material(nil), do: [auto_orient: false, rotate: 0, flip: nil]

  defp orientation_material(orientation) do
    [
      auto_orient: orientation.auto_orient,
      rotate: orientation.rotate,
      flip: orientation.flip
    ]
  end

  defp maybe_put_target_rule(material, nil), do: material

  defp maybe_put_target_rule(material, rule) do
    material ++ [target_rule: rule_material(rule)]
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
      enlarge: rule.enlarge
    ]
  end
end
