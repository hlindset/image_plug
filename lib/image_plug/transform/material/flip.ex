defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Operation.Flip do
  def material(%ImagePlug.Transform.Operation.Flip{} = operation) do
    [
      op: :flip,
      axis: operation.axis
    ]
  end
end
