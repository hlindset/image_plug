defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Rotate do
  def material(%ImagePlug.Transform.Rotate{} = operation) do
    [
      op: :rotate,
      angle: operation.angle
    ]
  end
end
