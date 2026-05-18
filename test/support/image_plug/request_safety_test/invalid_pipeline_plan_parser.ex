defmodule ImagePlug.RequestSafetyTest.InvalidPipelinePlanParser do
  @moduledoc false

  @behaviour ImagePlug.Parser

  @impl ImagePlug.Parser
  def parse(_conn, _opts) do
    {:ok,
     %ImagePlug.Plan{
       source: %ImagePlug.Plan.Source.Path{segments: ["images", "cat.jpg"]},
       pipelines: [:not_a_pipeline],
       output: %ImagePlug.Plan.Output{mode: :automatic},
       response: %ImagePlug.Plan.Response{}
     }}
  end

  @impl ImagePlug.Parser
  def handle_error(conn, {:error, reason}) do
    Plug.Conn.send_resp(conn, 400, inspect(reason))
  end
end
