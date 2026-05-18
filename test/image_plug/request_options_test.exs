defmodule ImagePlug.RequestOptionsTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Request.Options
  alias ImagePlug.SourceTest.CustomAdapter

  @base_opts [
    parser: ImagePlug.Parser.Imgproxy,
    sources: [
      path: {CustomAdapter, adapter: :path}
    ]
  ]

  test "validate! accepts clock as a zero-arity function" do
    clock = fn -> DateTime.utc_now() end

    assert Options.validate!(Keyword.put(@base_opts, :clock, clock))[:clock] == clock
  end

  test "validate! rejects malformed clock values before call opts are used" do
    for clock <- [:bad, ~U[2026-05-05 12:00:00Z], 100, fn value -> value end] do
      assert_raise ArgumentError,
                   ~r/invalid ImagePlug options: invalid value for :clock option/,
                   fn ->
                     Options.validate!(Keyword.put(@base_opts, :clock, clock))
                   end
    end
  end

  test "request options accept sources without root_url" do
    assert opts =
             Options.validate!(
               parser: ImagePlug.Parser.Imgproxy,
               sources: [
                 path: {CustomAdapter, adapter: :path}
               ]
             )

    assert opts[:sources][:path]
    refute Keyword.has_key?(opts, :root_url)
  end

  test "request options reject invalid source adapter config during init" do
    assert_raise ArgumentError, fn ->
      Options.validate!(
        parser: ImagePlug.Parser.Imgproxy,
        sources: [path: {CustomAdapter, :not_options}]
      )
    end
  end

  test "request options reject stale origin configuration after source integration" do
    assert_raise ArgumentError, fn ->
      Options.validate!(
        parser: ImagePlug.Parser.Imgproxy,
        sources: [path: {CustomAdapter, adapter: :path}],
        root_url: "https://origin.example"
      )
    end

    assert_raise ArgumentError, fn ->
      Options.validate!(
        parser: ImagePlug.Parser.Imgproxy,
        sources: [path: {CustomAdapter, adapter: :path}],
        origin_req_options: [plug: OriginImage]
      )
    end
  end
end
