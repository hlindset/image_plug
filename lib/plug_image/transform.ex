defmodule PlugImage.Transform do
  alias PlugImage.TransformState

  @callback execute(TransformState.t(), String.t()) :: TransformState.t()
end
