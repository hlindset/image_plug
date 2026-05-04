defmodule ImagePlug.ProcessorTest.Materializer do
  @moduledoc false

  alias ImagePlug.TransformState

  def materialize(%TransformState{} = state, opts) do
    send(
      Keyword.fetch!(opts, :test_pid),
      {:pipeline_event, Keyword.fetch!(opts, :test_ref), :materialized_between_pipelines}
    )

    ImagePlug.ImageMaterializer.materialize(state, opts)
  end
end
