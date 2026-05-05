defmodule ImagePlug.ProcessorTest.InvalidStateMaterializer do
  @moduledoc false

  alias ImagePlug.TransformState

  def materialize(%TransformState{} = state, _opts),
    do: {:ok, %TransformState{state | image: nil}}
end
