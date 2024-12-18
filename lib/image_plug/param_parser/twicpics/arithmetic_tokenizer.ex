defmodule ImagePlug.ParamParser.Twicpics.ArithmeticTokenizer do
  alias ImagePlug.ParamParser.Twicpics.Utils

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

  defp mk_int(value, left_pos, right_pos),
    do: {:int, value, left_pos, right_pos}

  defp mk_float_open(value, left_pos, right_pos),
    do: {:float_open, value, left_pos, right_pos}

  defp mk_exp_open(value, left_pos, right_pos),
    do: {:exp_open, value, left_pos, right_pos}

  defp mk_exp(value, left_pos, right_pos),
    do: {:exp, value, left_pos, right_pos}

  defp mk_float(value, left_pos, right_pos),
    do: {:float, value, left_pos, right_pos}

  defp mk_op(type, pos),
    do: {:op, type, pos}

  defp sci_to_num(sci) do
    [base_str, exponent_str] = String.split(sci, ~r/e/i)
    {base, ""} = Float.parse(base_str)
    {exponent, ""} = Integer.parse(exponent_str)
    base * :math.pow(10, exponent)
  end

  def tokenize(input, pos_offset \\ 0) do
    case do_parse(%State{input: input, pos: pos_offset}) do
      {:ok, tokens} ->
        {:ok,
         tokens
         |> Enum.reverse()
         |> Enum.map(fn
           {:int, int, pos_b, pos_e} -> mk_int(String.to_integer(int), pos_b, pos_e)
           {:float, int, pos_b, pos_e} -> mk_float(String.to_float(int), pos_b, pos_e)
           {:exp, exp_num, pos_b, pos_e} -> mk_float(sci_to_num(exp_num), pos_b, pos_e)
           other -> other
         end)}

      {:error, {_reason, _opts}} = error ->
        Utils.update_error_input(error, input)
    end
  end

  # we hit end of input, but no tokens have been processed
  defp do_parse(%State{input: "", tokens: []} = state) when state.paren_count == 0,
    do: Utils.unexpected_value_error(state.pos, ["(", "[0-9]"], found: :eoi)

  # just consume space characters
  defp do_parse(%State{input: <<char::utf8, _rest::binary>>} = state) when char in ~c[ ] do
    state |> consume_char() |> do_parse()
  end

  #
  # the following states are legal end of input locations as long as
  # we're not inside a parentheses: :int, :float, :exp and :right_paren
  #
  defp do_parse(%State{input: "", tokens: [{:int, _, _, _} | _] = tokens} = state)
       when state.paren_count == 0,
       do: {:ok, tokens}

  defp do_parse(%State{input: "", tokens: [{:float, _, _, _} | _] = tokens} = state)
       when state.paren_count == 0,
       do: {:ok, tokens}

  defp do_parse(%State{input: "", tokens: [{:exp, _, _, _} | _] = tokens} = state)
       when state.paren_count == 0,
       do: {:ok, tokens}

  defp do_parse(%State{input: "", tokens: [{:right_paren, _} | _] = tokens} = state)
       when state.paren_count == 0,
       do: {:ok, tokens}

  # first char in string
  defp do_parse(%State{input: <<char::utf8, _rest::binary>>, tokens: []} = state) do
    cond do
      char in ?0..?9 or char == ?- ->
        add_token(state, mk_int(<<char::utf8>>, state.pos, state.pos))

      # the only way to enter paren_count > 0 is through the first char
      char == ?( ->
        add_left_paren(state)

      true ->
        Utils.unexpected_value_error(state.pos, ["(", "[0-9]"], <<char::utf8>>)
    end
  end

  #
  # prev token: :left_paren
  #

  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:left_paren, _} | _]
         } = state
       ) do
    cond do
      char in ?0..?9 or char == ?- ->
        add_token(state, mk_int(<<char::utf8>>, state.pos, state.pos))

      char == ?( ->
        add_left_paren(state)

      true ->
        Utils.unexpected_value_error(state.pos, ["(", "[0-9]", "-"], <<char::utf8>>)
    end
  end

  # we hit end of input while the previous token was a :left_paren
  defp do_parse(%State{input: "", tokens: [{:left_paren, _} | _]} = state) do
    Utils.unexpected_value_error(state.pos, ["(", "[0-9]", "-"], :eoi)
  end

  #
  # prev token: :right_paren
  #

  # if last :right_paren has been closed, the expression is completed,
  # so no more characters are allowed
  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:right_paren, _} | _]
         } = state
       )
       when state.paren_count == 0,
       do: Utils.unexpected_value_error(state.pos, [:eoi], <<char::utf8>>)

  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:right_paren, _} | _]
         } = state
       )
       when state.paren_count > 0 do
    cond do
      char in @op_tokens -> add_token(state, mk_op(<<char::utf8>>, state.pos))
      char == ?) -> add_right_paren(state)
      true -> Utils.unexpected_value_error(state.pos, ["+", "-", "*", "/", ")"], <<char::utf8>>)
    end
  end

  # we hit end of input while the previous token was a :right_paren, but we're still inside a paren
  defp do_parse(%State{input: "", tokens: [{:right_paren, _} | _]} = state)
       when state.paren_count > 0 do
    Utils.unexpected_value_error(state.pos, ["+", "-", "*", "/", ")"], :eoi)
  end

  #
  # prev token: integer
  #

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
        replace_token(state, mk_int(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      char == ?. ->
        replace_token(state, mk_float_open(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      char == ?e or char == ?E ->
        replace_token(state, mk_exp_open(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      true ->
        Utils.unexpected_value_error(state.pos, ["[0-9]", "."], <<char::utf8>>)
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
        replace_token(state, mk_int(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      char == ?. ->
        replace_token(state, mk_float_open(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      char == ?e or char == ?E ->
        replace_token(state, mk_exp_open(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      char in @op_tokens ->
        add_token(state, mk_op(<<char::utf8>>, state.pos))

      char == ?) ->
        add_right_paren(state)

      true ->
        Utils.unexpected_value_error(
          state.pos,
          ["[0-9]", ".", "+", "-", "*", "/", ")"],
          <<char::utf8>>
        )
    end
  end

  # we hit eoi while on an :int token, and we're in a parentheses
  defp do_parse(%State{input: "", tokens: [{:int, _, _, _} | _]} = state)
       when state.paren_count > 0 do
    Utils.unexpected_value_error(state.pos, ["[0-9]", ".", "+", "-", "*", "/", ")"], :eoi)
  end

  #
  # prev token: :float_open
  # - it's not a valid float yet
  #

  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:float_open, cur_val, t_pos_b, _} | _]
         } = state
       ) do
    cond do
      char in ?0..?9 ->
        replace_token(state, mk_float(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      true ->
        Utils.unexpected_value_error(state.pos, ["[0-9]"], <<char::utf8>>)
    end
  end

  # we hit end of input while in a :float_open
  defp do_parse(%State{input: "", tokens: [{:float_open, _, _, _} | _]} = state),
    do: Utils.unexpected_value_error(state.pos, ["[0-9]"], :eoi)

  #
  # prev token: :float
  # - at this point it's a valid float
  #

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
        replace_token(state, mk_float(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      char == ?e or char == ?E ->
        replace_token(state, mk_exp_open(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      true ->
        Utils.unexpected_value_error(state.pos, ["[0-9]"], <<char::utf8>>)
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
        replace_token(state, mk_float(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      char == ?e or char == ?E ->
        replace_token(state, mk_exp_open(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      char in @op_tokens ->
        add_token(state, mk_op(<<char::utf8>>, state.pos))

      char == ?) ->
        add_right_paren(state)

      true ->
        Utils.unexpected_value_error(
          state.pos,
          ["[0-9]", "+", "-", "*", "/", ")"],
          <<char::utf8>>
        )
    end
  end

  # we hit eoi while on an :float token, and we're in a parentheses
  defp do_parse(%State{input: "", tokens: [{:float, _, _, _} | _]} = state)
       when state.paren_count > 0 do
    Utils.unexpected_value_error(state.pos, ["[0-9]", "+", "-", "*", "/", ")"], :eoi)
  end

  #
  # prev token: :exp_open
  # - at this point it's a not a valid exponential number
  #

  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:exp_open, cur_val, t_pos_b, _} | _]
         } = state
       ) do
    cond do
      char in ?0..?9 or char == ?- ->
        replace_token(state, mk_exp(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      true ->
        Utils.unexpected_value_error(state.pos, ["[0-9]", "-"], <<char::utf8>>)
    end
  end

  # we hit end of input while in a :float_open
  defp do_parse(%State{input: "", tokens: [{:exp_open, _, _, _} | _]} = state),
    do: Utils.unexpected_value_error(state.pos, ["[0-9]", "-"], :eoi)

  #
  # prev token: :exp
  # - we have a valid number in exponential notation
  #

  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:exp, cur_val, t_pos_b, _} | _]
         } = state
       )
       when state.paren_count == 0 do
    cond do
      char in ?0..?9 ->
        replace_token(state, mk_exp(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      true ->
        Utils.unexpected_value_error(state.pos, ["[0-9]"], <<char::utf8>>)
    end
  end

  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:exp, cur_val, t_pos_b, _} | _]
         } = state
       )
       when state.paren_count > 0 do
    cond do
      char in ?0..?9 ->
        replace_token(state, mk_exp(cur_val <> <<char::utf8>>, t_pos_b, state.pos))

      char in @op_tokens ->
        add_token(state, mk_op(<<char::utf8>>, state.pos))

      char == ?) ->
        add_right_paren(state)

      true ->
        Utils.unexpected_value_error(state.pos, ["[0-9]", "-"], <<char::utf8>>)
    end
  end

  #
  # prev token: :op
  #

  defp do_parse(
         %State{
           input: <<char::utf8, _rest::binary>>,
           tokens: [{:op, _, _} | _]
         } = state
       )
       when state.paren_count > 0 do
    cond do
      char in ?0..?9 or char == ?- ->
        add_token(state, mk_int(<<char::utf8>>, state.pos, state.pos))

      char == ?( ->
        add_left_paren(state)

      true ->
        Utils.unexpected_value_error(state.pos, ["[0-9]", "-", "("], <<char::utf8>>)
    end
  end

  # we hit eoi while on an :op token
  defp do_parse(%State{input: "", tokens: [{:op, _, _} | _]} = state) do
    Utils.unexpected_value_error(state.pos, ["[0-9]", "-", "("], :eoi)
  end
end
