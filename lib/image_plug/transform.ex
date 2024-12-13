defmodule ImagePlug.Transform do
  alias ImagePlug.TransformState
  alias ImagePlug.ArithmeticParser

  @callback execute(TransformState.t(), String.t()) :: TransformState.t()
end
