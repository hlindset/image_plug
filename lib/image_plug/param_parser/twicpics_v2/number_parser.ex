defmodule NumberParser do
  alias ImagePlug.ParamParser.TwicpicsV2.Utils

  @op_tokens ~c"+-*/"

  defmodule State do
    defstruct input: "", tokens: [], pos: 0, paren_count: 0
  end

  defp add_token(%State{tokens: tokens} = state, token),
    do: %State{state | tokens: [token | tokens]}

  defp replace_token(%State{tokens: [_head | tail]} = state, token),
    do: %State{state | tokens: [token | tail]}

  defp inc_paren_count(%State{paren_count: paren_count} = state),
    do: %State{state | paren_count: paren_count + 1}

  defp dec_paren_count(%State{paren_count: paren_count} = state),
    do: %State{state | paren_count: paren_count - 1}

  defp consume_char(%State{input: <<_char::utf8, rest::binary>>, pos: pos} = state),
    do: %State{state | input: rest, pos: pos + 1}

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
      char in ?0..?9 or char == ?- ->
        state
        |> add_token({:int, <<char::utf8>>, state.pos, state.pos})
        |> consume_char()
        |> do_parse()

      # the only way to enter paren_count > 0 is through the first char
      char == ?( ->
        state
        |> add_token({:left_paren, state.pos})
        |> inc_paren_count()
        |> consume_char()
        |> do_parse()

      true ->
        unexpected_char_error(state.pos, ["(", "[0-9]"], <<char::utf8>>)
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
      char in ?0..?9 or char == ?- ->
        state
        |> add_token({:int, <<char::utf8>>, state.pos, state.pos})
        |> consume_char()
        |> do_parse()

      char == ?( ->
        state
        |> add_token({:left_paren, state.pos})
        |> inc_paren_count()
        |> consume_char()
        |> do_parse()

      true ->
        unexpected_char_error(state.pos, ["(", "[0-9]"], <<char::utf8>>)
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
      char in @op_tokens ->
        state
        |> add_token({:op, <<char::utf8>>, state.pos})
        |> consume_char()
        |> do_parse()

      char == ?) ->
        state
        |> add_token({:right_paren, state.pos})
        |> dec_paren_count()
        |> consume_char()
        |> do_parse()

      true ->
        unexpected_char_error(state.pos, ["+", "-", "*", "/", ")"], <<char::utf8>>)
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
      char in ?0..?9 ->
        state
        |> replace_token({:int, cur_val <> <<char::utf8>>, t_pos_b, state.pos})
        |> consume_char()
        |> do_parse()

      char == ?. ->
        state
        |> replace_token({:float_open, cur_val <> <<char::utf8>>, t_pos_b})
        |> consume_char()
        |> do_parse()

      true ->
        unexpected_char_error(state.pos, ["[0-9]", "."], <<char::utf8>>)
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
      char in ?0..?9 ->
        state
        |> replace_token({:int, cur_val <> <<char::utf8>>, t_pos_b, state.pos})
        |> consume_char()
        |> do_parse()

      char == ?. ->
        state
        |> replace_token({:float_open, cur_val <> <<char::utf8>>, t_pos_b})
        |> consume_char()
        |> do_parse()

      char in @op_tokens ->
        state
        |> add_token({:op, <<char::utf8>>, state.pos})
        |> consume_char()
        |> do_parse()

      char == ?) ->
        state
        |> add_token({:right_paren, state.pos})
        |> dec_paren_count()
        |> consume_char()
        |> do_parse()

      true ->
        unexpected_char_error(state.pos, ["[0-9]", ".", "+", "-", "*", "/", ")"], <<char::utf8>>)
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
      char in ?0..?9 ->
        state
        |> replace_token({:float, cur_val <> <<char::utf8>>, t_pos_b, state.pos})
        |> consume_char()
        |> do_parse()

      true ->
        unexpected_char_error(state.pos, ["[0-9]"], <<char::utf8>>)
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
      char in ?0..?9 ->
        state
        |> replace_token({:float, cur_val <> <<char::utf8>>, t_pos_b, state.pos})
        |> consume_char()
        |> do_parse()

      true ->
        unexpected_char_error(state.pos, ["[0-9]"], <<char::utf8>>)
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
      char in ?0..?9 ->
        state
        |> replace_token({:float, cur_val <> <<char::utf8>>, t_pos_b, state.pos})
        |> consume_char()
        |> do_parse()

      char in @op_tokens ->
        state
        |> add_token({:op, <<char::utf8>>, state.pos})
        |> consume_char()
        |> do_parse()

      char == ?) ->
        state
        |> add_token({:right_paren, state.pos})
        |> dec_paren_count()
        |> consume_char()
        |> do_parse()

      true ->
        unexpected_char_error(state.pos, ["[0-9]", ".", "+", "-", "*", "/", ")"], <<char::utf8>>)
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
      char in ?0..?9 or char == ?- ->
        state
        |> add_token({:int, <<char::utf8>>, state.pos, state.pos})
        |> consume_char()
        |> do_parse()

      char == ?( ->
        state
        |> add_token({:left_paren, state.pos})
        |> inc_paren_count()
        |> consume_char()
        |> do_parse()

      true ->
        unexpected_char_error(state.pos, ["[0-9]", "("], <<char::utf8>>)
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
