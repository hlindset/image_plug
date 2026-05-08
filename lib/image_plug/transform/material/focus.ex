defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Operation.Focus do
  def material(%ImagePlug.Transform.Operation.Focus{} = operation) do
    [
      op: :focus,
      type: operation.type
    ]
  end
end
