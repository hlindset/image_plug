defimpl ImagePlug.Cache.Material, for: ImagePlug.Transform.Focus.FocusParams do
  def material(params) do
    [
      op: :focus,
      type: params.type
    ]
  end
end
