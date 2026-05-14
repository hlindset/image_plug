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
        origin_req_options: [plug: ImagePlug.Request.ProcessorTest.OriginShouldNotFetch]
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
        origin_req_options: [plug: ImagePlug.Request.ProcessorTest.OriginShouldNotFetch]
      )

    assert conn.status == 422
    assert conn.resp_body == "invalid image transform"
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "parser validation failures return before origin fetch" do
    conn =
      ImagePlug.call(conn(:get, "/_/raw/plain/images/cat.jpg"),
        parser: ImagePlug.Parser.Imgproxy,
        root_url: "http://origin.test",
        origin_req_options: [plug: ImagePlug.Request.ProcessorTest.OriginShouldNotFetch]
      )

    assert conn.status == 400
  end

  test "invalid composition parser failures return before source identity, cache lookup, and origin" do
    for path <- [
          "/_/pd:-1/plain/images/cat.jpg",
          "/_/bg:256:0:0/plain/images/cat.jpg",
          "/_/bga:1.1/plain/images/cat.jpg"
        ] do
      conn =
        ImagePlug.call(conn(:get, path),
          parser: ImagePlug.Parser.Imgproxy,
          root_url: "not-a-valid-origin-url",
          cache: {CacheProbe, []},
          origin_req_options: [plug: ImagePlug.Request.ProcessorTest.OriginShouldNotFetch]
        )

      assert conn.status == 400
      refute_received :cache_lookup
      refute_received :cache_put
    end
  end

  test "expired imgproxy requests return before source identity and cache work" do
    conn =
      ImagePlug.call(conn(:get, "/_/exp:100/plain/images/cat.jpg"),
        parser: ImagePlug.Parser.Imgproxy,
        root_url: "not-a-valid-origin-url",
        clock: fn -> DateTime.from_unix!(101) end,
        cache: {CacheProbe, []},
        origin_req_options: [plug: ImagePlug.Request.ProcessorTest.OriginShouldNotFetch]
      )

    assert conn.status == 400
    assert conn.resp_body =~ "expired_request"
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "invalid imgproxy signatures return before source identity, cache lookup, and origin" do
    conn =
      ImagePlug.call(
        conn(:get, "/invalid/w:300/plain/images/cat.jpg"),
        ImagePlug.init(
          parser: ImagePlug.Parser.Imgproxy,
          root_url: "not-a-valid-origin-url",
          imgproxy: [
            signature: [
              keys: ["746573742d6b6579"],
              salts: ["746573742d73616c74"]
            ]
          ],
          cache: {CacheProbe, []},
          origin_req_options: [plug: ImagePlug.Request.ProcessorTest.OriginShouldNotFetch]
        )
      )

    assert conn.status == 403
    assert conn.resp_body =~ "invalid_signature"
    refute_received :cache_lookup
    refute_received :cache_put
  end

  test "invalid imgproxy signatures return before origin fetch with a valid root URL" do
    conn =
      ImagePlug.call(
        conn(:get, "/invalid/w:300/plain/images/cat.jpg"),
        ImagePlug.init(
          parser: ImagePlug.Parser.Imgproxy,
          root_url: "http://origin.test",
          imgproxy: [
            signature: [
              keys: ["746573742d6b6579"],
              salts: ["746573742d73616c74"]
            ]
          ],
          origin_req_options: [plug: ImagePlug.Request.ProcessorTest.OriginShouldNotFetch]
        )
      )

    assert conn.status == 403
    assert conn.resp_body =~ "invalid_signature"
  end

  test "invalid imgproxy signatures return before option parsing at the plug boundary" do
    conn =
      ImagePlug.call(
        conn(:get, "/invalid/raw/plain/images/cat.jpg"),
        ImagePlug.init(
          parser: ImagePlug.Parser.Imgproxy,
          root_url: "http://origin.test",
          imgproxy: [
            signature: [
              keys: ["746573742d6b6579"],
              salts: ["746573742d73616c74"]
            ]
          ],
          origin_req_options: [plug: ImagePlug.Request.ProcessorTest.OriginShouldNotFetch]
        )
      )

    assert conn.status == 403
    assert conn.resp_body =~ "invalid_signature"
    refute conn.resp_body =~ "unsupported_option"
  end
end
