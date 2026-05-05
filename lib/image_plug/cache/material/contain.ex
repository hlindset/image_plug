defimpl ImagePlug.Cache.Material, for: ImagePlug.Transform.Contain.ContainParams do
  def material(%{type: :ratio} = params) do
    [
      op: :contain,
      type: params.type,
      ratio: params.ratio,
      letterbox: params.letterbox
    ]
  end

  def material(params) do
    [
      op: :contain,
      type: params.type,
      width: params.width,
      height: params.height,
      constraint: params.constraint,
      letterbox: params.letterbox
    ]
  end
end
