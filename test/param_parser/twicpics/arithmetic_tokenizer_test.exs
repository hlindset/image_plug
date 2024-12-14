defmodule ImagePlug.ParamParser.Twicpics.ArithmeticTokenizerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePlug.ParamParser.Twicpics.ArithmeticTokenizer

  describe "successful parsing" do
    test "parses a single integer" do
      input = "123"
      {:ok, tokens} = ArithmeticTokenizer.tokenize(input)

      assert tokens == [{:int, 123, 0, 2}]
    end

    test "parses a single negative integer" do
      input = "-123"
      {:ok, tokens} = ArithmeticTokenizer.tokenize(input)

      assert tokens == [{:int, -123, 0, 3}]
    end

    test "parses a single floating-point number" do
      input = "123.45"
      {:ok, tokens} = ArithmeticTokenizer.tokenize(input)

      assert tokens == [{:float, 123.45, 0, 5}]
    end

    test "parses a single negative floating-point number" do
      input = "-123.45"
      {:ok, tokens} = ArithmeticTokenizer.tokenize(input)

      assert tokens == [{:float, -123.45, 0, 6}]
    end

    test "parses a simple addition expression with parentheses" do
      input = "(123+456)"
      {:ok, tokens} = ArithmeticTokenizer.tokenize(input)

      assert tokens == [
               {:left_paren, 0},
               {:int, 123, 1, 3},
               {:op, "+", 4},
               {:int, 456, 5, 7},
               {:right_paren, 8}
             ]
    end

    test "parses a complex nested expression" do
      input = "((123+456)*789)"
      {:ok, tokens} = ArithmeticTokenizer.tokenize(input)

      assert tokens == [
               {:left_paren, 0},
               {:left_paren, 1},
               {:int, 123, 2, 4},
               {:op, "+", 5},
               {:int, 456, 6, 8},
               {:right_paren, 9},
               {:op, "*", 10},
               {:int, 789, 11, 13},
               {:right_paren, 14}
             ]
    end

    test "parses an expression with mixed operators" do
      input = "(123+456*789)"
      {:ok, tokens} = ArithmeticTokenizer.tokenize(input)

      assert tokens == [
               {:left_paren, 0},
               {:int, 123, 1, 3},
               {:op, "+", 4},
               {:int, 456, 5, 7},
               {:op, "*", 8},
               {:int, 789, 9, 11},
               {:right_paren, 12}
             ]
    end

    test "parses an expression with multiple levels of nesting" do
      input = "(((123+456)-789)/2)"
      {:ok, tokens} = ArithmeticTokenizer.tokenize(input)

      assert tokens == [
               {:left_paren, 0},
               {:left_paren, 1},
               {:left_paren, 2},
               {:int, 123, 3, 5},
               {:op, "+", 6},
               {:int, 456, 7, 9},
               {:right_paren, 10},
               {:op, "-", 11},
               {:int, 789, 12, 14},
               {:right_paren, 15},
               {:op, "/", 16},
               {:int, 2, 17, 17},
               {:right_paren, 18}
             ]
    end

    test "parses a complex statement with all operators" do
      assert ArithmeticTokenizer.tokenize("(10/20*(4+5)-5*-1)") ==
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
                  {:op, "-", 12},
                  {:int, 5, 13, 13},
                  {:op, "*", 14},
                  {:int, -1, 15, 16},
                  {:right_paren, 17}
                ]}
    end

    test "parses an expression with whitespace" do
      input = " (   123 + 456 * ( 789 -    10 )    ) "
      {:ok, tokens} = ArithmeticTokenizer.tokenize(input)

      assert tokens == [
               {:left_paren, 1},
               {:int, 123, 5, 7},
               {:op, "+", 9},
               {:int, 456, 11, 13},
               {:op, "*", 15},
               {:left_paren, 17},
               {:int, 789, 19, 21},
               {:op, "-", 23},
               {:int, 10, 28, 29},
               {:right_paren, 31},
               {:right_paren, 36}
             ]
    end
  end

  describe "unexpected_value_error/3" do
    test "invalid character at the start of input" do
      input = "x123"
      {:error, {:unexpected_char, opts}} = ArithmeticTokenizer.tokenize(input)

      assert Keyword.get(opts, :pos) == 0
      assert Keyword.get(opts, :expected) == ["(", "[0-9]"]
      assert Keyword.get(opts, :found) == "x"
    end

    test "invalid character after a valid integer" do
      input = "123x"
      {:error, {:unexpected_char, opts}} = ArithmeticTokenizer.tokenize(input)

      assert Keyword.get(opts, :pos) == 3
      assert Keyword.get(opts, :expected) == ["[0-9]", "."]
      assert Keyword.get(opts, :found) == "x"
    end

    test "invalid character after a valid float" do
      input = "12.3x"
      {:error, {:unexpected_char, opts}} = ArithmeticTokenizer.tokenize(input)

      assert Keyword.get(opts, :pos) == 4
      assert Keyword.get(opts, :expected) == ["[0-9]"]
      assert Keyword.get(opts, :found) == "x"
    end

    test "mismatched parentheses" do
      input = "(123"
      {:error, {:unexpected_char, opts}} = ArithmeticTokenizer.tokenize(input)

      assert Keyword.get(opts, :pos) == 4
      assert Keyword.get(opts, :expected) == ["[0-9]", ".", "+", "-", "*", "/", ")"]
      assert Keyword.get(opts, :found) == :eoi
    end

    test "operators outside parentheses" do
      input = "123+456"
      {:error, {:unexpected_char, opts}} = ArithmeticTokenizer.tokenize(input)

      assert Keyword.get(opts, :pos) == 3
      assert Keyword.get(opts, :expected) == ["[0-9]", "."]
      assert Keyword.get(opts, :found) == "+"
    end

    test "unexpected character after a valid expression" do
      input = "(123+456)x"
      {:error, {:unexpected_char, opts}} = ArithmeticTokenizer.tokenize(input)

      assert Keyword.get(opts, :pos) == 9
      assert Keyword.get(opts, :expected) == [:eoi]
      assert Keyword.get(opts, :found) == "x"
    end

    test "unclosed float at the end of input" do
      input = "123."
      {:error, {:unexpected_char, opts}} = ArithmeticTokenizer.tokenize(input)

      assert Keyword.get(opts, :pos) == 4
      assert Keyword.get(opts, :expected) == ["[0-9]"]
      assert Keyword.get(opts, :found) == :eoi
    end

    test "unexpected end of input after opening parenthesis" do
      input = "("
      {:error, {:unexpected_char, opts}} = ArithmeticTokenizer.tokenize(input)

      assert Keyword.get(opts, :pos) == 1
      assert Keyword.get(opts, :expected) == ["(", "[0-9]", "-"]
      assert Keyword.get(opts, :found) == :eoi
    end
  end
end
