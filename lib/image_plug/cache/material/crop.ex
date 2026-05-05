defimpl ImagePlug.Cache.Material, for: ImagePlug.Transform.Crop do
  def material(%ImagePlug.Transform.Crop{} = operation) do
    [
      op: :crop,
      width: operation.width,
      height: operation.height,
      crop_from: operation.crop_from
    ]
  end
end
