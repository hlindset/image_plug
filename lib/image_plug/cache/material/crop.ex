defimpl ImagePlug.Cache.Material, for: ImagePlug.Transform.Crop.CropParams do
  def material(params) do
    [
      op: :crop,
      width: params.width,
      height: params.height,
      crop_from: params.crop_from
    ]
  end
end
