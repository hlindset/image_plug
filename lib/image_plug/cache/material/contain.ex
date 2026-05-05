defimpl ImagePlug.Cache.Material, for: ImagePlug.Transform.Contain do
  def material(%ImagePlug.Transform.Contain{type: :ratio} = operation) do
    [
      op: :contain,
      type: operation.type,
      ratio: operation.ratio,
      letterbox: operation.letterbox
    ]
  end

  def material(%ImagePlug.Transform.Contain{} = operation) do
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
