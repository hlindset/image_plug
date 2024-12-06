defmodule ImagePlug.Twicpics.KeyValueParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePlug.ParamParser.TwicpicsV2.KeyValueParser

  test "successful parse output returns correct key positions" do
    assert KeyValueParser.parse("k1=v1/k2=v2/k3=v3") ==
             {:ok,
              [
                {"k1", "v1", 0},
                {"k2", "v2", 6},
                {"k3", "v3", 12}
              ]}

    assert KeyValueParser.parse("k1=v1/k20=v20/k300=v300/k4000=v4000") ==
             {:ok,
              [
                {"k1", "v1", 0},
                {"k20", "v20", 6},
                {"k300", "v300", 14},
                {"k4000", "v4000", 24}
              ]}
  end

  test ":expected_eq error returns correct position" do
    assert KeyValueParser.parse("k1=v1/k20=v20/k300") == {:error, {:expected_eq, pos: 19}}
  end

  test ":expected_key error returns correct position" do
    assert KeyValueParser.parse("k1=v1/k20=v20/") == {:error, {:expected_key, pos: 14}}
  end

  test ":expected_value error returns correct position" do
    assert KeyValueParser.parse("k1=v1/k20=") == {:error, {:expected_value, pos: 10}}
  end
end
