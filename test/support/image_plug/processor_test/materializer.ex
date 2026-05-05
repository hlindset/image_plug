defmodule ImagePlug.ProcessorTest.Materializer do
  @moduledoc false

  alias ImagePlug.Transform.State

  def materialize(%State{} = state, opts) do
    send(
      Keyword.fetch!(opts, :test_pid),
      {:pipeline_event, Keyword.fetch!(opts, :test_ref), :materialized_between_pipelines}
    )

    ImagePlug.Transform.Materializer.materialize(state, opts)
  end
end
