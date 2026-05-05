defmodule ImagePlug.RequestSafetyTest do
  use ExUnit.Case, async: true
  import Plug.Test

  defmodule InvalidPlanParser do
    @behaviour ImagePlug.Parser

    @impl ImagePlug.Parser
    def parse(_conn, _opts) do
      {:ok,
       %ImagePlug.Plan{
         source: :invalid_source,
         pipelines: [%ImagePlug.Plan.Pipeline{operations: []}],
         output: %ImagePlug.Plan.Output{mode: :automatic},
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

  test "plug validates product-neutral plan shape before source identity resolution" do
    conn =
      ImagePlug.call(conn(:get, "/_/plain/images/cat.jpg"),
        parser: InvalidPlanParser,
        root_url: "http://origin.test"
      )

    assert conn.status == 400
    assert conn.resp_body =~ "unsupported_source"
  end
end
