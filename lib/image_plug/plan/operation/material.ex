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

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Operation.CropGuided do
  def material(%ImagePlug.Plan.Operation.CropGuided{} = operation) do
    ImagePlug.Transform.KeyData.data(operation)
  end
end

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Operation.CropRegion do
  def material(%ImagePlug.Plan.Operation.CropRegion{} = operation) do
    ImagePlug.Transform.KeyData.data(operation)
  end
end

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Operation.Canvas do
  def material(%ImagePlug.Plan.Operation.Canvas{} = operation) do
    ImagePlug.Transform.KeyData.data(operation)
  end
end

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Operation.AutoOrient do
  def material(%ImagePlug.Plan.Operation.AutoOrient{}) do
    [op: :auto_orient]
  end
end

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Operation.Rotate do
  def material(%ImagePlug.Plan.Operation.Rotate{} = operation) do
    [op: :rotate, angle: operation.angle]
  end
end

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Operation.Flip do
  def material(%ImagePlug.Plan.Operation.Flip{} = operation) do
    [op: :flip, axis: operation.axis]
  end
end

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Operation.ResizeFit do
  def material(%ImagePlug.Plan.Operation.ResizeFit{} = operation) do
    [
      op: :resize_fit,
      size: ImagePlug.Transform.Material.material(operation.size),
      enlargement: operation.enlargement,
      min_width: material_or_nil(operation.min_width),
      min_height: material_or_nil(operation.min_height),
      zoom_x: operation.zoom_x,
      zoom_y: operation.zoom_y
    ]
  end

  defp material_or_nil(nil), do: nil
  defp material_or_nil(value), do: ImagePlug.Transform.Material.material(value)
end

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Operation.Resize do
  def material(%ImagePlug.Plan.Operation.Resize{} = operation) do
    ImagePlug.Transform.KeyData.data(operation)
  end
end

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Operation.ResizeCover do
  def material(%ImagePlug.Plan.Operation.ResizeCover{} = operation) do
    [
      op: :resize_cover,
      size: ImagePlug.Transform.Material.material(operation.size),
      enlargement: operation.enlargement,
      guide: ImagePlug.Transform.Material.material(operation.guide),
      min_width: material_or_nil(operation.min_width),
      min_height: material_or_nil(operation.min_height),
      zoom_x: operation.zoom_x,
      zoom_y: operation.zoom_y,
      x_offset: operation.x_offset,
      y_offset: operation.y_offset
    ]
  end

  defp material_or_nil(nil), do: nil
  defp material_or_nil(value), do: ImagePlug.Transform.Material.material(value)
end

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Operation.ResizeStretch do
  def material(%ImagePlug.Plan.Operation.ResizeStretch{} = operation) do
    [
      op: :resize_stretch,
      size: ImagePlug.Transform.Material.material(operation.size),
      enlargement: operation.enlargement,
      min_width: material_or_nil(operation.min_width),
      min_height: material_or_nil(operation.min_height),
      zoom_x: operation.zoom_x,
      zoom_y: operation.zoom_y
    ]
  end

  defp material_or_nil(nil), do: nil
  defp material_or_nil(value), do: ImagePlug.Transform.Material.material(value)
end

defimpl ImagePlug.Transform.Material, for: ImagePlug.Plan.Operation.ResizeAuto do
  def material(%ImagePlug.Plan.Operation.ResizeAuto{} = operation) do
    [
      op: :resize_auto,
      size: ImagePlug.Transform.Material.material(operation.size),
      enlargement: operation.enlargement,
      guide: ImagePlug.Transform.Material.material(operation.guide),
      min_width: material_or_nil(operation.min_width),
      min_height: material_or_nil(operation.min_height),
      zoom_x: operation.zoom_x,
      zoom_y: operation.zoom_y,
      x_offset: operation.x_offset,
      y_offset: operation.y_offset,
      rule: :imgproxy_orientation_match_v1
    ]
  end

  defp material_or_nil(nil), do: nil
  defp material_or_nil(value), do: ImagePlug.Transform.Material.material(value)
end
