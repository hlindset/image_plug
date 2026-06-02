defmodule ImagePipe.Request.ProcessorTest.Materializer do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Transform]

  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State

  def materialize(%State{} = state, opts) do
    Materializer.materialize(state, opts)
  end
end
