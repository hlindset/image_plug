defmodule Imagex.Transformation do
  alias Imagex.TransformState

  @callback execute(TransformState.t(), String.t()) :: TransformState.t()
end
