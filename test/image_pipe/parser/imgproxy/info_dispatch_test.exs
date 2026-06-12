defmodule ImagePipe.Parser.Imgproxy.InfoDispatchTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Parser.Imgproxy
  alias ImagePipe.Plan

  defp opts, do: [imgproxy: []]

  test "parses an unsafe /info URL into an imgproxy_info render plan" do
    conn = conn(:get, "/info/unsafe/plain/https://example.com/a.jpg")

    assert {:ok,
            %Plan{render: {:custom, ImagePipe.Parser.Imgproxy.InfoRenderer, _}, pipelines: []} =
              plan} =
             Imgproxy.parse(conn, opts())

    assert plan.output == nil
  end

  test "the /info prefix is peeled (signature verified on the remainder, not on \"info\")" do
    conn = conn(:get, "/info/unsafe/plain/https://example.com/a.jpg")
    assert {:ok, %Plan{}} = Imgproxy.parse(conn, opts())
  end

  test "an info URL with options still parses (options are accepted, ignored)" do
    conn = conn(:get, "/info/unsafe/rs:fill:100:100/plain/https://example.com/a.jpg")

    assert {:ok, %Plan{render: {:custom, ImagePipe.Parser.Imgproxy.InfoRenderer, _}}} =
             Imgproxy.parse(conn, opts())
  end

  test "an info URL with a missing plain source errors (does not build a render plan)" do
    conn = conn(:get, "/info/unsafe/plain/")
    assert {:error, {:missing_source_identifier, "plain"}} = Imgproxy.parse(conn, opts())
  end
end
