defmodule NumberParser do
  alias ImagePlug.ParamParser.TwicpicsV2.Utils

  @op_tokens ~c"+-*/"

  defmodule State do
    defstruct input: "", tokens: [], pos: 0, paren_count: 0
  end

  defp consume_char(%State{input: <<_char::utf8, rest::binary>>, pos: pos} = state),
    do: %State{state | input: rest, pos: pos + 1}

  defp add_token(%State{tokens: tokens} = state, token),
    do: %State{state | tokens: [token | tokens]} |> consume_char() |> do_parse()

  defp replace_token(%State{tokens: [_head | tail]} = state, token),
    do: %State{state | tokens: [token | tail]} |> consume_char() |> do_parse()

  defp add_left_paren(%State{} = state) do
    %State{state | paren_count: state.paren_count + 1}
    |> add_token({:left_paren, state.pos})
  end

  defp add_right_paren(%State{} = state) do
    %State{state | paren_count: state.paren_count - 1}
    |> add_token({:right_paren, state.pos})
  end

  def parse(input, pos_offset \\ 0) do
    case do_parse(%State{input: input, pos: pos_offset}) do
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
  defp do_parse(%State{input: "", tokens: []} = state) when state.paren_count == 0,
    do: unexpected_char_error(state.pos, ["(", "[0-9]"], found: :eoi)

  defp do_parse(%State{input: "", tokens: [{:float_open, _, _} | _]} = state),
    do: unexpected_char_error(state.pos, ["[0-9]"], found: :eoi)

  defp do_parse(%State{input: ""} = state) when state.paren_count > 0,
    do: unexpected_char_error(state.pos, [")"], found: :eoi)

  defp do_parse(%State{input: "", tokens: [{:int, _, _, _} | _] = tokens}),
    do: {:ok, tokens}

  defp do_parse(%State{input: "", tokens: [{:float, _, _, _} | _] = tokens}),
    do: {:ok, tokens}

  defp do_parse(%State{input: "", tokens: [{:right_paren, _} | _] = tokens}),
    do: {:ok, tokens}

  # first char in string
  defp do_parse(%State{input: <<char::utf8, _rest::binary>>, tokens: []} = state) do
    cond do
      char in ?0..?9 or char == ?- -> add_token(state, {:int, <<char::utf8>>, state.pos, state.pos})
      # the only way to enter paren_count > 0 is through the first char
      char == ?( -> add_left_paren(state)
      true -> unexpected_char_error(state.pos, ["(", "[0-9]"], <<char::utf8>>)
    end
  end

  # prev token: :left_paren
  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:left_paren, _} | _]
         } = state
       ) do
    cond do
      char in ?0..?9 or char == ?- -> add_token(state, {:int, <<char::utf8>>, state.pos, state.pos})
      char == ?( -> add_left_paren(state)
      true -> unexpected_char_error(state.pos, ["(", "[0-9]"], <<char::utf8>>)
    end
  end

  # prev token: :right_paren
  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:right_paren, _} | _]
         } = state
       )
       when state.paren_count == 0,
       do: unexpected_char_error(state.pos, [:eoi], <<char::utf8>>)

  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:right_paren, _} | _]
         } = state
       ) do
    cond do
      char in @op_tokens -> add_token(state, {:op, <<char::utf8>>, state.pos})
      char == ?) -> add_right_paren(state)
      true -> unexpected_char_error(state.pos, ["+", "-", "*", "/", ")"], <<char::utf8>>)
    end
  end

  # prev token: {:int, n}
  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:int, cur_val, t_pos_b, _} | _]
         } = state
       )
       when state.paren_count == 0 do
    # not in parens, so it's only a number literal, and no ops are allowed
    cond do
      char in ?0..?9 -> replace_token(state, {:int, cur_val <> <<char::utf8>>, t_pos_b, state.pos})
      char == ?. -> replace_token(state, {:float_open, cur_val <> <<char::utf8>>, t_pos_b})
      true -> unexpected_char_error(state.pos, ["[0-9]", "."], <<char::utf8>>)
    end
  end

  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:int, cur_val, t_pos_b, _} | _]
         } = state
       )
       when state.paren_count > 0 do
    cond do
      char in ?0..?9 -> replace_token(state, {:int, cur_val <> <<char::utf8>>, t_pos_b, state.pos})
      char == ?. -> replace_token(state, {:float_open, cur_val <> <<char::utf8>>, t_pos_b})
      char in @op_tokens -> add_token(state, {:op, <<char::utf8>>, state.pos})
      char == ?) -> add_right_paren(state)
      true -> unexpected_char_error(state.pos, ["[0-9]", ".", "+", "-", "*", "/", ")"], <<char::utf8>>)
    end
  end

  # prev token: {:float_open, n} - which means that it's not a valid float yet
  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:float_open, cur_val, t_pos_b, _} | _]
         } = state
       ) do
    cond do
      char in ?0..?9 -> replace_token(state, {:float, cur_val <> <<char::utf8>>, t_pos_b, state.pos})
      true -> unexpected_char_error(state.pos, ["[0-9]"], <<char::utf8>>)
    end
  end

  # prev token: {:float, n} - at this point it's a valid float
  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:float, cur_val, t_pos_b, _} | _]
         } = state
       )
       when state.paren_count == 0 do
    # not in parens, so it's only a number literal, and no ops are allowed
    cond do
      char in ?0..?9 -> replace_token(state, {:float, cur_val <> <<char::utf8>>, t_pos_b, state.pos})
      true -> unexpected_char_error(state.pos, ["[0-9]"], <<char::utf8>>)
    end
  end

  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:float, cur_val, t_pos_b, _} | _]
         } = state
       )
       when state.paren_count > 0 do
    cond do
      char in ?0..?9 -> replace_token(state, {:float, cur_val <> <<char::utf8>>, t_pos_b, state.pos})
      char in @op_tokens -> add_token(state, {:op, <<char::utf8>>, state.pos})
      char == ?) -> add_right_paren(state)
      true -> unexpected_char_error(state.pos, ["[0-9]", ".", "+", "-", "*", "/", ")"], <<char::utf8>>)
    end
  end

  # prev token: {:op, v}
  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:op, _, _} | _]
         } = state
       )
       when state.paren_count > 0 do
    cond do
      char in ?0..?9 or char == ?- -> add_token(state, {:int, <<char::utf8>>, state.pos, state.pos})
      char == ?( -> add_left_paren(state)
      true -> unexpected_char_error(state.pos, ["[0-9]", "("], <<char::utf8>>)
    end
  end

  defp unexpected_char_error(pos, expected, found) do
    {:error, {:unexpected_char, pos: pos, expected: expected, found: found}}
  end

  def pos({:int, _value, pos_b, pos_e}), do: {pos_b, pos_e}
  def pos({:float_open, _value, pos_b, pos_e}), do: {pos_b, pos_e}
  def pos({:float, _value, pos_b, pos_e}), do: {pos_b, pos_e}
  def pos({:left_paren, pos}), do: {pos, pos}
  def pos({:right_paren, pos}), do: {pos, pos}
  def pos({:op, _optype, pos}), do: {pos, pos}
end
