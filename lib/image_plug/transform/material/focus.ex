defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Focus do
  def material(%ImagePlug.Transform.Focus{} = operation) do
    [
      op: :focus,
      type: operation.type
    ]
  end
end
