defmodule ImagePlug.Twicpics.NumberParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  test "successful parse output returns correct key positions" do
    assert NumberParser.parse("10") == {:ok, [{:int, 10, 0, 1}]}

    assert NumberParser.parse("(10+10)") ==
             {:ok,
              [
                {:left_paren, 0},
                {:int, 10, 1, 2},
                {:op, "+", 3},
                {:int, 10, 4, 5},
                {:right_paren, 6}
              ]}

    assert NumberParser.parse("(10/20*(4+5)+5*-1)") ==
             {:ok,
              [
                {:left_paren, 0},
                {:int, 10, 1, 2},
                {:op, "/", 3},
                {:int, 20, 4, 5},
                {:op, "*", 6},
                {:left_paren, 7},
                {:int, 4, 8, 8},
                {:op, "+", 9},
                {:int, 5, 10, 10},
                {:right_paren, 11},
                {:op, "+", 12},
                {:int, 5, 13, 13},
                {:op, "*", 14},
                {:int, -1, 15, 16},
                {:right_paren, 17}
              ]}
  end
end
