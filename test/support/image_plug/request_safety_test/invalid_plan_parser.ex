defmodule ImagePlug.RequestSafetyTest.InvalidPlanParser do
  @moduledoc false

  @behaviour ImagePlug.Parser

  @impl ImagePlug.Parser
  def parse(_conn, _opts) do
    {:ok,
     %ImagePlug.Plan{
       source: %ImagePlug.Plan.Source.Plain{path: ["images", "cat.jpg"]},
       pipelines: [%ImagePlug.Plan.Pipeline{operations: []}],
       output: :invalid_output,
       policy: %ImagePlug.Plan.Policy{},
       cache: %ImagePlug.Plan.Cache{},
       response: %ImagePlug.Plan.Response{}
     }}
  end

  @impl ImagePlug.Parser
  def handle_error(conn, {:error, reason}) do
    Plug.Conn.send_resp(conn, 400, inspect(reason))
  end
end
