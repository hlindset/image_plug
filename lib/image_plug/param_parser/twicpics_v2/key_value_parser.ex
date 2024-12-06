defmodule ImagePlug.ParamParser.TwicpicsV2.KeyValueParser do
  def parse(input) do
    case parse_pairs(input, [], 0) do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_pairs("", acc, _pos), do: {:ok, acc}

  # pos + 1 because key is expected at the next char
  defp parse_pairs("/", acc, pos), do: {:error, {:expected_key, pos: pos + 1}}

  defp parse_pairs(<<"/"::binary, input::binary>>, acc, pos),
    do: parse_pairs(input, acc, pos + 1)

  defp parse_pairs(input, acc, key_pos) do
    with {:ok, {key, rest, value_pos}} <- extract_key(input, key_pos),
         {:ok, {value, rest, next_pos}} <- extract_value(rest, value_pos) do
      parse_pairs(rest, [{key, value, key_pos} | acc], next_pos)
    else
      {:error, _reason} = error -> error
    end
  end

  defp extract_key(input, pos) do
    case String.split(input, "=", parts: 2) do
      [key, rest] -> {:ok, {key, rest, pos + String.length(key) + 1}}
      [rest] -> {:error, {:expected_eq, pos: pos + String.length(rest) + 1}}
    end
  end

  defp extract_value(input, pos) do
    case extract_until_slash_or_end(input, "", pos) do
      {"", rest, new_pos} -> {:error, {:expected_value, pos: pos}}
      {value, rest, new_pos} -> {:ok, {value, rest, new_pos}}
    end
  end

  defp extract_until_slash_or_end("", acc, pos), do: {acc, "", pos}

  defp extract_until_slash_or_end(<<"/"::binary, rest::binary>>, acc, pos) do
    if balanced_parens?(acc) do
      {acc, "/" <> rest, pos}
    else
      extract_until_slash_or_end(rest, acc <> "/", pos + 1)
    end
  end

  defp extract_until_slash_or_end(<<char::utf8, rest::binary>>, acc, pos) do
    extract_until_slash_or_end(rest, acc <> <<char::utf8>>, pos + 1)
  end

  def balanced_parens?(value) when is_binary(value) do
    balanced_parens?(value, [])
  end

  # both sting and stack exhausted, we're in balance!
  defp balanced_parens?("", []), do: true

  # string is empty, but stack is not, so a paren has not been closed
  defp balanced_parens?("", _stack), do: false

  # add "(" to stack
  defp balanced_parens?(<<"("::binary, rest::binary>>, stack),
    do: balanced_parens?(rest, ["(" | stack])

  # we found a ")", remove "(" from stack and continue
  defp balanced_parens?(<<")"::binary, rest::binary>>, ["(" | stack]),
    do: balanced_parens?(rest, stack)

  # we found a ")", but head of stack doesn't match
  defp balanced_parens?(<<")"::binary, rest::binary>>, _stack), do: false

  # consume all other chars
  defp balanced_parens?(<<char::utf8, rest::binary>>, stack), do: balanced_parens?(rest, stack)
end
