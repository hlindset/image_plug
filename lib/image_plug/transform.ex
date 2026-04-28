defmodule ImagePlug.Transform do
  alias ImagePlug.TransformState

  @callback execute(TransformState.t(), struct()) :: TransformState.t()
end
