defmodule ImagePipe.Parser.Imgproxy.InfoDispatchTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Parser.Imgproxy
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Render

  defp opts, do: [imgproxy: []]

  test "parses an unsafe /info URL into an imgproxy_info render plan" do
    conn = conn(:get, "/info/unsafe/plain/https://example.com/a.jpg")

    assert {:ok,
            %Plan{render: %Render{module: ImagePipe.Parser.Imgproxy.InfoRenderer}, pipelines: []} =
              plan} =
             Imgproxy.parse(conn, opts())

    refute plan.output.mode == :automatic
  end

  test "the /info prefix is peeled (signature verified on the remainder, not on \"info\")" do
    conn = conn(:get, "/info/unsafe/plain/https://example.com/a.jpg")
    assert {:ok, %Plan{}} = Imgproxy.parse(conn, opts())
  end

  test "an info URL with options still parses (options are accepted, ignored)" do
    conn = conn(:get, "/info/unsafe/rs:fill:100:100/plain/https://example.com/a.jpg")

    assert {:ok, %Plan{render: %Render{module: ImagePipe.Parser.Imgproxy.InfoRenderer}}} =
             Imgproxy.parse(conn, opts())
  end
end
