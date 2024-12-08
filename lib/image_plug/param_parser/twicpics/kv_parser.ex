defmodule ImagePlug.ParamParser.Twicpics.KVParser do
  alias ImagePlug.ParamParser.Twicpics.Utils

  def parse(input, valid_keys, pos_offset \\ 0) do
    case parse_pairs(input, [], valid_keys, pos_offset) do
      {:ok, result} -> {:ok, Enum.reverse(result)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_pairs("", acc, _valid_keys, _pos), do: {:ok, acc}

  # pos + 1 because key is expected at the next char
  defp parse_pairs("/", _acc, _valid_keys, pos), do: {:error, {:expected_key, pos: pos + 1}}

  defp parse_pairs(<<"/"::binary, input::binary>>, acc, valid_keys, pos),
    do: parse_pairs(input, acc, valid_keys, pos + 1)

  defp parse_pairs(input, acc, valid_keys, key_pos) do
    with {:ok, {key, rest, value_pos}} <- extract_key(input, valid_keys, key_pos),
         {:ok, {value, rest, next_pos}} <- extract_value(rest, value_pos) do
      parse_pairs(rest, [{key, value, key_pos} | acc], valid_keys, next_pos)
    else
      {:error, _reason} = error -> error
    end
  end

  defp extract_key(input, valid_keys, pos) do
    case String.split(input, "=", parts: 2) do
      [key, rest] ->
        if key in valid_keys,
          do: {:ok, {key, rest, pos + String.length(key) + 1}},
          else: Utils.unexpected_value_error(pos, valid_keys, key)

      [rest] ->
        Utils.unexpected_value_error(pos + String.length(rest), ["="], :eoi)
    end
  end

  defp extract_value(input, pos) do
    case extract_until_slash_or_end(input, "", pos) do
      {"", _rest, new_pos} -> {:error, {:expected_value, pos: new_pos}}
      {value, rest, new_pos} -> {:ok, {value, rest, new_pos}}
    end
  end

  defp extract_until_slash_or_end("", acc, pos), do: {acc, "", pos}

  defp extract_until_slash_or_end(<<"/"::binary, rest::binary>>, acc, pos) do
    if Utils.balanced_parens?(acc) do
      {acc, "/" <> rest, pos}
    else
      extract_until_slash_or_end(rest, acc <> "/", pos + 1)
    end
  end

  defp extract_until_slash_or_end(<<char::utf8, rest::binary>>, acc, pos) do
    extract_until_slash_or_end(rest, acc <> <<char::utf8>>, pos + 1)
  end
end
