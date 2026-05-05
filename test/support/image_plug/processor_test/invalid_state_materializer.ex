defmodule ImagePlug.Runtime.ProcessorTest.InvalidStateMaterializer do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Transform]

  alias ImagePlug.Transform.State

  def materialize(%State{} = state, _opts),
    do: {:ok, %State{state | image: nil}}
end
