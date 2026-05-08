defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.Operation.AutoOrient do
  def material(%ImagePlug.Transform.Operation.AutoOrient{}) do
    [
      op: :auto_orient
    ]
  end
end
