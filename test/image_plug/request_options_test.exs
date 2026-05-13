defmodule ImagePlug.RequestOptionsTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Request.Options

  @base_opts [
    parser: ImagePlug.Parser.Imgproxy,
    root_url: "http://origin.test"
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
end
