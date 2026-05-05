defimpl ImagePlug.Cache.Material, for: ImagePlug.Transform.Scale.ScaleParams do
  def material(%{type: :ratio} = params) do
    [
      op: :scale,
      type: params.type,
      ratio: params.ratio
    ]
  end

  def material(params) do
    [
      op: :scale,
      type: params.type,
      width: params.width,
      height: params.height
    ]
  end
end
