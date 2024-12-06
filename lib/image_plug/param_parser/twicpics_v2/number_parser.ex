defmodule NumberParser do
  alias ImagePlug.ParamParser.TwicpicsV2.Utils

  def parse(input, pos_offset \\ 0) do
    case do_parse(input, [], 0, pos_offset) do
      {:ok, tokens} ->
        {:ok,
         tokens
         |> Enum.reverse()
         |> Enum.map(fn
           {:int, int} -> {:int, String.to_integer(int)}
           {:float, int} -> {:float, String.to_float(int)}
           other -> other
         end)}

      {:error, {reason, opts}} = error ->
        Utils.update_error_input(error, input)
    end
  end

  # end of input
  defp do_parse("", [], pcount, pos) when pcount == 0,
    do: {:error, {:unexpected_char, pos: pos, expected: ["(", "[0-9]"], found: :eoi}}

  defp do_parse("", [{:float_open, _} | _], _pcount, pos),
    do: {:error, {:unexpected_char, pos: pos, expected: ["[0-9]"], found: :eoi}}

  defp do_parse("", acc, pcount, pos) when pcount > 0,
    do: {:error, {:unexpected_char, pos: pos, expected: [")"], found: :eoi}}

  defp do_parse("", [{:int, _} | _] = acc, _pcount, _pos), do: {:ok, acc}
  defp do_parse("", [{:float, _} | _] = acc, _pcount, _pos), do: {:ok, acc}
  defp do_parse("", [:right_paren | _] = acc, _pcount, _pos), do: {:ok, acc}

  # first char in string
  defp do_parse(<<char::utf8, rest::binary>>, [], pcount, pos) do
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:int, <<char>>}], pcount, pos + 1)

      # the only way to enter pcount > 0 is through the first char
      char == ?( ->
        do_parse(rest, [:left_paren], pcount + 1, pos + 1)

      true ->
        {:error, {:unexpected_char, pos: pos, expected: ["(", "[0-9]"], found: <<char::utf8>>}}
    end
  end

  # prev token: :left_paren
  defp do_parse(<<char::utf8, rest::binary>>, [:left_paren | _] = acc, pcount, pos) do
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:int, <<char>>} | acc], pcount, pos + 1)

      char == ?( ->
        do_parse(rest, [:left_paren | acc], pcount + 1, pos + 1)

      true ->
        {:error, {:unexpected_char, pos: pos, expected: ["(", "[0-9]"], found: <<char::utf8>>}}
    end
  end

  # prev token: :right_paren
  defp do_parse(<<char::utf8, rest::binary>>, [:right_paren | _] = acc, pcount, pos)
       when pcount == 0 do
    {:error, {:unexpected_char, pos: pos, expected: [:eoi], found: <<char::utf8>>}}
  end

  defp do_parse(<<char::utf8, rest::binary>>, [:right_paren | _] = acc, pcount, pos)
       when pcount > 0 do
    cond do
      char == ?+ ->
        do_parse(rest, [{:op, "+"} | acc], pcount, pos + 1)

      char == ?- ->
        do_parse(rest, [{:op, "-"} | acc], pcount, pos + 1)

      char == ?* ->
        do_parse(rest, [{:op, "*"} | acc], pcount, pos + 1)

      char == ?/ ->
        do_parse(rest, [{:op, "/"} | acc], pcount, pos + 1)

      char == ?) ->
        do_parse(rest, [:right_paren | acc], pcount - 1, pos + 1)

      true ->
        {:error,
         {:unexpected_char, pos: pos, expected: ["+", "-", "*", "/", ")"], found: <<char::utf8>>}}
    end
  end

  # prev token: {:int, n}
  defp do_parse(<<char::utf8, rest::binary>>, [{:int, cur_val} | acc_tail] = acc, pcount, pos)
       when pcount == 0 do
    # not in parens, so it's only a number literal, and no ops are allowed
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:int, cur_val <> <<char>>} | acc_tail], pcount, pos + 1)

      char == ?. ->
        do_parse(rest, [{:float_open, cur_val <> "."} | acc_tail], pcount, pos + 1)

      true ->
        {:error, {:unexpected_char, pos: pos, expected: ["[0-9]", "."], found: <<char::utf8>>}}
    end
  end

  defp do_parse(<<char::utf8, rest::binary>>, [{:int, cur_val} | acc_tail] = acc, pcount, pos)
       when pcount > 0 do
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:int, cur_val <> <<char>>} | acc_tail], pcount, pos + 1)

      char == ?. ->
        do_parse(rest, [{:float_open, cur_val <> "."} | acc_tail], pcount, pos + 1)

      char == ?+ ->
        do_parse(rest, [{:op, "+"} | acc], pcount, pos + 1)

      char == ?- ->
        do_parse(rest, [{:op, "-"} | acc], pcount, pos + 1)

      char == ?* ->
        do_parse(rest, [{:op, "*"} | acc], pcount, pos + 1)

      char == ?/ ->
        do_parse(rest, [{:op, "/"} | acc], pcount, pos + 1)

      char == ?) ->
        do_parse(rest, [:right_paren | acc], pcount - 1, pos + 1)

      true ->
        {:error,
         {:unexpected_char,
          pos: pos, expected: ["[0-9]", ".", "+", "-", "*", "/", ")"], found: <<char::utf8>>}}
    end
  end

  # prev token: {:float_open, n} - which means that it's not a valid float yet
  defp do_parse(
         <<char::utf8, rest::binary>>,
         [{:float_open, cur_val} | acc_tail] = acc,
         pcount,
         pos
       ) do
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:float, cur_val <> <<char>>} | acc_tail], pcount, pos + 1)

      true ->
        {:error, {:unexpected_char, pos: pos, expected: ["[0-9]"], found: <<char::utf8>>}}
    end
  end

  # prev token: {:float, n} - at this point it's a valid float
  defp do_parse(<<char::utf8, rest::binary>>, [{:float, cur_val} | acc_tail] = acc, pcount, pos)
       when pcount == 0 do
    # not in parens, so it's only a number literal, and no ops are allowed
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:float, cur_val <> <<char>>} | acc_tail], pcount, pos + 1)

      true ->
        {:error, {:unexpected_char, pos: pos, expected: ["[0-9]"], found: <<char::utf8>>}}
    end
  end

  defp do_parse(<<char::utf8, rest::binary>>, [{:float, cur_val} | acc_tail] = acc, pcount, pos)
       when pcount > 0 do
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:float, cur_val <> <<char>>} | acc_tail], pcount, pos + 1)

      char == ?+ ->
        do_parse(rest, [{:op, "+"} | acc], pcount, pos + 1)

      char == ?- ->
        do_parse(rest, [{:op, "-"} | acc], pcount, pos + 1)

      char == ?* ->
        do_parse(rest, [{:op, "*"} | acc], pcount, pos + 1)

      char == ?/ ->
        do_parse(rest, [{:op, "/"} | acc], pcount, pos + 1)

      char == ?) ->
        do_parse(rest, [:right_paren | acc], pcount - 1, pos + 1)

      true ->
        {:error,
         {:unexpected_char,
          pos: pos, expected: ["[0-9]", ".", "+", "-", "*", "/", ")"], found: <<char::utf8>>}}
    end
  end

  # prev token: {:op, v}
  defp do_parse(<<char::utf8, rest::binary>>, [{:op, _} | _] = acc, pcount, pos)
       when pcount > 0 do
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:int, <<char>>} | acc], pcount, pos + 1)

      char == ?( ->
        do_parse(rest, [:left_paren | acc], pcount + 1, pos + 1)

      true ->
        {:error, {:unexpected_char, pos: pos, expected: ["[0-9]", "("], found: <<char::utf8>>}}
    end
  end
end
