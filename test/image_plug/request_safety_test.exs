defmodule ImagePlug.RequestSafetyTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePlug.RequestSafetyTest.CacheProbe
  alias ImagePlug.RequestSafetyTest.InvalidPipelinePlanParser
  alias ImagePlug.RequestSafetyTest.InvalidPlanParser

  test "plug validates product-neutral plan shape before source identity resolution" do
    conn =
      ImagePlug.call(conn(:get, "/_/plain/images/cat.jpg"),
        parser: InvalidPlanParser,
        root_url: "http://origin.test"
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
  end

  test "invalid product-neutral plan fails before source identity, cache lookup, and origin" do
    conn =
      ImagePlug.call(conn(:get, "/_/plain/images/cat.jpg"),
        parser: InvalidPlanParser,
        root_url: "not-a-valid-origin-url",
        cache: {CacheProbe, []},
        origin_req_options: [plug: ImagePlug.Runtime.ProcessorTest.OriginShouldNotFetch]
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "invalid pipeline plan fails before source identity, cache lookup, and origin" do
    conn =
      ImagePlug.call(conn(:get, "/_/plain/images/cat.jpg"),
        parser: InvalidPipelinePlanParser,
        root_url: "not-a-valid-origin-url",
        cache: {CacheProbe, []},
        origin_req_options: [plug: ImagePlug.Runtime.ProcessorTest.OriginShouldNotFetch]
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "parser validation failures return before origin fetch" do
    conn =
      ImagePlug.call(conn(:get, "/_/raw/plain/images/cat.jpg"),
        parser: ImagePlug.Parser.Native,
        root_url: "http://origin.test",
        origin_req_options: [plug: ImagePlug.Runtime.ProcessorTest.OriginShouldNotFetch]
      )

    assert conn.status == 400
  end

  test "expired native requests return before source identity and cache work" do
    conn =
      ImagePlug.call(conn(:get, "/_/exp:100/plain/images/cat.jpg"),
        parser: ImagePlug.Parser.Native,
        root_url: "not-a-valid-origin-url",
        now: 101,
        cache: {CacheProbe, []},
        origin_req_options: [plug: ImagePlug.Runtime.ProcessorTest.OriginShouldNotFetch]
      )

    assert conn.status == 400
    assert conn.resp_body =~ "expired_request"
    refute_received :cache_lookup
    refute_received :cache_put
  end
end
