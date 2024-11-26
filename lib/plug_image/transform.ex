defmodule ImagePlug.Transform do
  alias ImagePlug.TransformState

  @callback execute(TransformState.t(), String.t()) :: TransformState.t()
end
