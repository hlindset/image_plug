defmodule ImagePlug.RequestSafetyTest do
  use ExUnit.Case, async: true
  import Plug.Test

  defmodule CacheProbe do
    def get(_key, _opts), do: send(self(), :cache_lookup)
    def put(_key, _entry, _opts), do: send(self(), :cache_put)
  end

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

  test "expired native requests return before source identity and cache work" do
    conn =
      ImagePlug.call(conn(:get, "/_/exp:100/plain/images/cat.jpg"),
        parser: ImagePlug.Parser.Native,
        root_url: "not-a-valid-origin-url",
        now: 101,
        cache: {CacheProbe, []},
        origin_req_options: [plug: ImagePlug.ProcessorTest.OriginShouldNotFetch]
      )

    assert conn.status == 400
    assert conn.resp_body =~ "expired_request"
    refute_received :cache_lookup
    refute_received :cache_put
  end
end
