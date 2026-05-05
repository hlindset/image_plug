defimpl ImagePlug.Cache.Material, for: ImagePlug.Transform.Cover.CoverParams do
  def material(%{type: :ratio} = params) do
    [
      op: :cover,
      type: params.type,
      ratio: params.ratio
    ]
  end

  def material(params) do
    [
      op: :cover,
      type: params.type,
      width: params.width,
      height: params.height,
      constraint: params.constraint
    ]
  end
end
