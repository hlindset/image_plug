defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Flip do
  def material(%ImagePlug.Transform.Flip{} = operation) do
    [
      op: :flip,
      axis: operation.axis
    ]
  end
end
