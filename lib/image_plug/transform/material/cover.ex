defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Operation.Cover do
  def material(%ImagePlug.Transform.Operation.Cover{type: :ratio} = operation) do
    [
      op: :cover,
      type: operation.type,
      ratio: operation.ratio
    ]
  end

  def material(%ImagePlug.Transform.Operation.Cover{} = operation) do
    [
      op: :cover,
      type: operation.type,
      width: operation.width,
      height: operation.height,
      constraint: operation.constraint
    ]
  end
end
