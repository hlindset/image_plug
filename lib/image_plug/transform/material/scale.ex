defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Operation.Scale do
  def material(%ImagePlug.Transform.Operation.Scale{type: :ratio} = operation) do
    [
      op: :scale,
      type: operation.type,
      ratio: operation.ratio
    ]
  end

  def material(%ImagePlug.Transform.Operation.Scale{} = operation) do
    [
      op: :scale,
      type: operation.type,
      width: operation.width,
      height: operation.height
    ]
  end
end
