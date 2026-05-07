defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Operation.Rotate do
  def material(%ImagePlug.Transform.Operation.Rotate{} = operation) do
    [
      op: :rotate,
      angle: operation.angle
    ]
  end
end
