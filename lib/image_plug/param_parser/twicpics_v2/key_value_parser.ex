defmodule KeyValueParser do
  def parse(input) do
    parse_pairs(input, [], 0)
  end

  def parse(_input), do: []

  defp parse_pairs("", acc, _pos), do: Enum.reverse(acc)

  defp parse_pairs(<<"/"::binary, input::binary>>, acc, pos) do
    parse_pairs(input, acc, pos + 1)
  end

  defp parse_pairs(input, acc, key_pos) do
    {key, rest, value_pos} = extract_key(input, key_pos)
    {value, rest, after_value_pos} = extract_value(rest, value_pos)
    next_acc = [{key, value, key_pos} | acc]
    parse_pairs(rest, next_acc, after_value_pos)
  end

  defp extract_key(input, pos) do
    case String.split(input, "=", parts: 2) do
      [key, rest] -> {key, rest, pos + String.length(key) + 1}
      _ -> raise "Invalid input: Missing '=' in #{inspect(input)}"
    end
  end

  defp extract_value(input, pos) do
    extract_until_slash_or_end(input, "", pos)
  end

  defp extract_until_slash_or_end("", acc, pos), do: {acc, "", pos}

  defp extract_until_slash_or_end(<<"/"::binary, rest::binary>>, acc, pos) do
    if balanced_parentheses?(acc) do
      {acc, rest, pos + 1}
    else
      extract_until_slash_or_end(rest, acc <> "/", pos + 1)
    end
  end

  defp extract_until_slash_or_end(<<char::utf8, rest::binary>>, acc, pos) do
    extract_until_slash_or_end(rest, acc <> <<char::utf8>>, pos + 1)
  end

  def balanced_parentheses?(value) when is_binary(value) do
    value
    |> String.graphemes()
    |> Enum.filter(&(&1 in ["(", ")"]))
    |> balanced_parentheses?([])
  end

  # both items and stack exhausted, we're in balance!
  defp balanced_parentheses?([], []), do: true

  # items is empty, but stack is not, so a paren has not been closed
  defp balanced_parentheses?([], _stack), do: false

  # add "(" to stack
  defp balanced_parentheses?(["(" = next | rest], stack),
    do: balanced_parentheses?(rest, [next | stack])

  # we found a ")", remove "(" from stack
  defp balanced_parentheses?([")" | rest], ["(" | stack]), do: balanced_parentheses?(rest, stack)

  # and anything unhandled by now is a bogus closing paren
  defp balanced_parentheses?(_items, _stack), do: false

  def print_and_parse(input) do
    IO.puts(input <> ":")
    KeyValueParser.parse(input) |> IO.inspect(syntax_colors: IO.ANSI.syntax_colors())
    IO.puts("")
  end

  def example do
    KeyValueParser.print_and_parse("k1=v1/k2=v2/k3=v3")
    KeyValueParser.print_and_parse("k1=v1/k20=v20/k3=v3")
    KeyValueParser.print_and_parse("k1=v1/k201=v201/k30=v30")
    nil
  end
end
