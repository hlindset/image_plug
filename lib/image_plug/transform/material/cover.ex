defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Cover do
  def material(%ImagePlug.Transform.Cover{type: :ratio} = operation) do
    [
      op: :cover,
      type: operation.type,
      ratio: operation.ratio
    ]
  end

  def material(%ImagePlug.Transform.Cover{} = operation) do
    [
      op: :cover,
      type: operation.type,
      width: operation.width,
      height: operation.height,
      constraint: operation.constraint
    ]
  end
end
