defmodule ImagePlug.ProcessorTest.InvalidStateMaterializer do
  @moduledoc false

  alias ImagePlug.Transform.State

  def materialize(%State{} = state, _opts),
    do: {:ok, %State{state | image: nil}}
end
