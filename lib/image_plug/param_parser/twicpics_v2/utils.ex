defmodule ImagePlug.ParamParser.TwicpicsV2.Utils do
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
  defp balanced_parens?(<<")"::binary, _rest::binary>>, _stack), do: false

  # consume all other chars
  defp balanced_parens?(<<_char::utf8, rest::binary>>, stack), do: balanced_parens?(rest, stack)

  def update_error_input({:error, {reason, opts}}, input) do
    {:error, {reason, Keyword.put(opts, :input, input)}}
  end

  def token_pos({:int, _value, pos_b, pos_e}), do: {pos_b, pos_e}
  def token_pos({:float_open, _value, pos_b, pos_e}), do: {pos_b, pos_e}
  def token_pos({:float, _value, pos_b, pos_e}), do: {pos_b, pos_e}
  def token_pos({:left_paren, pos}), do: {pos, pos}
  def token_pos({:right_paren, pos}), do: {pos, pos}
  def token_pos({:op, _optype, pos}), do: {pos, pos}

  def unexpected_char_error(pos, expected, found) do
    {:error, {:unexpected_char, pos: pos, expected: expected, found: found}}
  end
end
