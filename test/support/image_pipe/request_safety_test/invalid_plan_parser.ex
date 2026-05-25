defmodule ImagePipe.RequestSafetyTest.InvalidPlanParser do
  @moduledoc false

  @behaviour ImagePipe.Parser

  @impl ImagePipe.Parser
  def parse(_conn, _opts) do
    {:ok,
     %ImagePipe.Plan{
       source: %ImagePipe.Plan.Source.Path{segments: ["images", "cat.jpg"]},
       pipelines: [%ImagePipe.Plan.Pipeline{operations: []}],
       output: :invalid_output,
       response: %ImagePipe.Plan.Response{}
     }}
  end

  @impl ImagePipe.Parser
  def handle_error(conn, {:error, reason}) do
    Plug.Conn.send_resp(conn, 400, inspect(reason))
  end
end
