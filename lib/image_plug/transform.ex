defmodule ImagePlug.Transform do
  @moduledoc false

  alias ImagePlug.TransformState

  @callback execute(TransformState.t(), struct()) :: TransformState.t()
  @callback metadata(params :: term()) :: map()

  @optional_callbacks metadata: 1
end
