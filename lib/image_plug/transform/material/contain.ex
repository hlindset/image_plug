defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Operation.Contain do
  def material(%ImagePlug.Transform.Operation.Contain{type: :ratio} = operation) do
    [
      op: :contain,
      type: operation.type,
      ratio: operation.ratio,
      letterbox: operation.letterbox
    ]
  end

  def material(%ImagePlug.Transform.Operation.Contain{} = operation) do
    [
      op: :contain,
      type: operation.type,
      width: operation.width,
      height: operation.height,
      constraint: operation.constraint,
      letterbox: operation.letterbox
    ]
  end
end
