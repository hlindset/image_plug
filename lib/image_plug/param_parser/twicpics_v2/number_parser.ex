defmodule NumberParser do
  alias ImagePlug.ParamParser.TwicpicsV2.Utils

  def parse(input, pos_offset \\ 0) do
    case do_parse(input, [], 0, pos_offset) do
      {:ok, tokens} ->
        {:ok,
         tokens
         |> Enum.reverse()
         |> Enum.map(fn
           {:int, int, pos_b, pos_e} -> {:int, String.to_integer(int), pos_b, pos_e}
           {:float, int, pos_b, pos_e} -> {:float, String.to_float(int), pos_b, pos_e}
           other -> other
         end)}

      {:error, {reason, opts}} = error ->
        Utils.update_error_input(error, input)
    end
  end

  # end of input
  defp do_parse("", [], paren_count, pos) when paren_count == 0,
    do: {:error, {:unexpected_char, pos: pos, expected: ["(", "[0-9]"], found: :eoi}}

  defp do_parse("", [{:float_open, _, _} | _], _paren_count, pos),
    do: {:error, {:unexpected_char, pos: pos, expected: ["[0-9]"], found: :eoi}}

  defp do_parse("", acc, paren_count, pos) when paren_count > 0,
    do: {:error, {:unexpected_char, pos: pos, expected: [")"], found: :eoi}}

  defp do_parse("", [{:int, _value, _t_pos_s, _t_pos_e} | _] = acc, _paren_count, _pos), do: {:ok, acc}
  defp do_parse("", [{:float, _value, _t_pos_s, _t_pos_e} | _] = acc, _paren_count, _pos), do: {:ok, acc}
  defp do_parse("", [{:right_paren, _t_pos} | _] = acc, _paren_count, _pos), do: {:ok, acc}

  # first char in string
  defp do_parse(<<char::utf8, rest::binary>>, [], paren_count, pos) do
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:int, <<char>>, pos, pos}], paren_count, pos + 1)

        # the only way to enter paren_count > 0 is through the first char
      char == ?( ->
        do_parse(rest, [{:left_paren, pos}], paren_count + 1, pos + 1)

      true ->
        {:error, {:unexpected_char, pos: pos, expected: ["(", "[0-9]"], found: <<char::utf8>>}}
    end
  end

  # prev token: :left_paren
  defp do_parse(<<char::utf8, rest::binary>>, [{:left_paren, _t_pos} | _] = acc, paren_count, pos) do
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:int, <<char>>, pos, pos} | acc], paren_count, pos + 1)

      char == ?( ->
        do_parse(rest, [{:left_paren, pos} | acc], paren_count + 1, pos + 1)

      true ->
        {:error, {:unexpected_char, pos: pos, expected: ["(", "[0-9]"], found: <<char::utf8>>}}
    end
  end

  # prev token: :right_paren
  defp do_parse(<<char::utf8, rest::binary>>, [{:right_paren, _t_pos} | _] = acc, paren_count, pos)
       when paren_count == 0 do
    {:error, {:unexpected_char, pos: pos, expected: [:eoi], found: <<char::utf8>>}}
  end

  defp do_parse(<<char::utf8, rest::binary>>, [{:right_paren, _t_pos} | _] = acc, paren_count, pos)
       when paren_count > 0 do
    cond do
      char == ?+ ->
        do_parse(rest, [{:op, "+", pos} | acc], paren_count, pos + 1)

      char == ?- ->
        do_parse(rest, [{:op, "-", pos} | acc], paren_count, pos + 1)

      char == ?* ->
        do_parse(rest, [{:op, "*", pos} | acc], paren_count, pos + 1)

      char == ?/ ->
        do_parse(rest, [{:op, "/", pos} | acc], paren_count, pos + 1)

      char == ?) ->
        do_parse(rest, [{:right_paren, pos} | acc], paren_count - 1, pos + 1)

      true ->
        {:error,
         {:unexpected_char, pos: pos, expected: ["+", "-", "*", "/", ")"], found: <<char::utf8>>}}
    end
  end

  # prev token: {:int, n}
  defp do_parse(<<char::utf8, rest::binary>>, [{:int, cur_val, t_pos_b, _t_pos_e} | acc_tail] = acc, paren_count, pos)
       when paren_count == 0 do
    # not in parens, so it's only a number literal, and no ops are allowed
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:int, cur_val <> <<char>>, t_pos_b, pos} | acc_tail], paren_count, pos + 1)

      char == ?. ->
        do_parse(rest, [{:float_open, cur_val <> ".", t_pos_b} | acc_tail], paren_count, pos + 1)

      true ->
        {:error, {:unexpected_char, pos: pos, expected: ["[0-9]", "."], found: <<char::utf8>>}}
    end
  end

  defp do_parse(<<char::utf8, rest::binary>>, [{:int, cur_val, t_pos_b, _t_pos_e} | acc_tail] = acc, paren_count, pos)
       when paren_count > 0 do
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:int, cur_val <> <<char>>, t_pos_b, pos} | acc_tail], paren_count, pos + 1)

      char == ?. ->
        do_parse(rest, [{:float_open, cur_val <> ".", t_pos_b, pos} | acc_tail], paren_count, pos + 1)

      char == ?+ ->
        do_parse(rest, [{:op, "+", pos} | acc], paren_count, pos + 1)

      char == ?- ->
        do_parse(rest, [{:op, "-", pos} | acc], paren_count, pos + 1)

      char == ?* ->
        do_parse(rest, [{:op, "*", pos} | acc], paren_count, pos + 1)

      char == ?/ ->
        do_parse(rest, [{:op, "/", pos} | acc], paren_count, pos + 1)

      char == ?) ->
        do_parse(rest, [{:right_paren, pos} | acc], paren_count - 1, pos + 1)

      true ->
        {:error,
         {:unexpected_char,
          pos: pos, expected: ["[0-9]", ".", "+", "-", "*", "/", ")"], found: <<char::utf8>>}}
    end
  end

  # prev token: {:float_open, n} - which means that it's not a valid float yet
  defp do_parse(
         <<char::utf8, rest::binary>>,
         [{:float_open, cur_val, t_pos_b, _t_pos_e} | acc_tail] = acc,
         paren_count,
         pos
       ) do
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:float, cur_val <> <<char>>, t_pos_b, pos} | acc_tail], paren_count, pos + 1)

      true ->
        {:error, {:unexpected_char, pos: pos, expected: ["[0-9]"], found: <<char::utf8>>}}
    end
  end

  # prev token: {:float, n} - at this point it's a valid float
  defp do_parse(<<char::utf8, rest::binary>>, [{:float, cur_val, t_pos_b, _t_pos_e} | acc_tail] = acc, paren_count, pos)
       when paren_count == 0 do
    # not in parens, so it's only a number literal, and no ops are allowed
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:float, cur_val <> <<char>>, t_pos_b, pos} | acc_tail], paren_count, pos + 1)

      true ->
        {:error, {:unexpected_char, pos: pos, expected: ["[0-9]"], found: <<char::utf8>>}}
    end
  end

  defp do_parse(<<char::utf8, rest::binary>>, [{:float, cur_val, t_pos_b, _t_pos_e} | acc_tail] = acc, paren_count, pos)
       when paren_count > 0 do
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:float, cur_val <> <<char>>, t_pos_b, pos} | acc_tail], paren_count, pos + 1)

      char == ?+ ->
        do_parse(rest, [{:op, "+", pos} | acc], paren_count, pos + 1)

      char == ?- ->
        do_parse(rest, [{:op, "-", pos} | acc], paren_count, pos + 1)

      char == ?* ->
        do_parse(rest, [{:op, "*", pos} | acc], paren_count, pos + 1)

      char == ?/ ->
        do_parse(rest, [{:op, "/", pos} | acc], paren_count, pos + 1)

      char == ?) ->
        do_parse(rest, [{:right_paren, pos} | acc], paren_count - 1, pos + 1)

      true ->
        {:error,
         {:unexpected_char,
          pos: pos, expected: ["[0-9]", ".", "+", "-", "*", "/", ")"], found: <<char::utf8>>}}
    end
  end

  # prev token: {:op, v}
  defp do_parse(<<char::utf8, rest::binary>>, [{:op, _optype, _t_pos} | _] = acc, paren_count, pos)
       when paren_count > 0 do
    cond do
      char in ?0..?9 ->
        do_parse(rest, [{:int, <<char>>, pos, pos} | acc], paren_count, pos + 1)

      char == ?( ->
        do_parse(rest, [{:left_paren, pos} | acc], paren_count + 1, pos + 1)

      true ->
        {:error, {:unexpected_char, pos: pos, expected: ["[0-9]", "("], found: <<char::utf8>>}}
    end
  end

  def pos({:int, _value, pos_b, pos_e}), do: {pos_b, pos_e}
  def pos({:float_open, _value, pos_b, pos_e}), do: {pos_b, pos_e}
  def pos({:float, _value, pos_b, pos_e}), do: {pos_b, pos_e}
  def pos({:left_paren, pos}), do: {pos, pos}
  def pos({:right_paren, pos}), do: {pos, pos}
  def pos({:op, _optype, pos}), do: {pos, pos}
end
