defimpl ImagePlug.Transform.Material, for: ImagePlug.Transform.AutoOrient do
  def material(%ImagePlug.Transform.AutoOrient{}) do
    [
      op: :auto_orient
    ]
  end
end
