defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Scale do
  def material(%ImagePlug.Transform.Scale{type: :ratio} = operation) do
    [
      op: :scale,
      type: operation.type,
      ratio: operation.ratio
    ]
  end

  def material(%ImagePlug.Transform.Scale{} = operation) do
    [
      op: :scale,
      type: operation.type,
      width: operation.width,
      height: operation.height
    ]
  end
end
