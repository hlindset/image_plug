defmodule ImagePlug.Runtime.ProcessorTest.Materializer do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Transform]

  alias ImagePlug.Transform.Materializer
  alias ImagePlug.Transform.State

  def materialize(%State{} = state, opts) do
    send(
      Keyword.fetch!(opts, :test_pid),
      {:pipeline_event, Keyword.fetch!(opts, :test_ref), :materialized_between_pipelines}
    )

    Materializer.materialize(state, opts)
  end
end
