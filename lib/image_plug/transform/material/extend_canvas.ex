defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.ExtendCanvas do
  def material(%ImagePlug.Transform.ExtendCanvas{} = operation) do
    [
      op: :extend_canvas,
      rule: operation.rule,
      gravity: operation.gravity,
      x_offset: operation.x_offset,
      y_offset: operation.y_offset,
      background: operation.background
    ]
  end
end
