defmodule ImagePlug.RuntimeOptionsTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Runtime.Options

  @base_opts [
    parser: ImagePlug.Parser.Native,
    root_url: "http://origin.test"
  ]

  test "validate! accepts now as an integer Unix timestamp" do
    assert Options.validate!(Keyword.put(@base_opts, :now, 100))[:now] == 100
  end

  test "validate! accepts now as a DateTime" do
    now = ~U[2026-05-05 12:00:00Z]

    assert Options.validate!(Keyword.put(@base_opts, :now, now))[:now] == now
  end

  test "validate! accepts now as a zero-arity function" do
    now = fn -> 100 end

    assert Options.validate!(Keyword.put(@base_opts, :now, now))[:now] == now
  end

  test "validate! rejects malformed now values before call opts are used" do
    for now <- [:bad, "100", 1.5, {:ok, 100}, fn value -> value end] do
      assert_raise ArgumentError,
                   ~r/invalid ImagePlug options: invalid value for :now option/,
                   fn ->
                     Options.validate!(Keyword.put(@base_opts, :now, now))
                   end
    end
  end
end
