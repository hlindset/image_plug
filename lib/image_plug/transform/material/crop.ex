defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Operation.Crop do
  def material(%ImagePlug.Transform.Operation.Crop{crop_from: :gravity} = operation) do
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

  def material(%ImagePlug.Transform.Operation.Crop{} = operation) do
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
    material ++ [target_rule: ImagePlug.Transform.Geometry.DimensionRule.material(rule)]
  end
end
