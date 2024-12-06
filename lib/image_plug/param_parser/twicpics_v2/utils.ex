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
  defp balanced_parens?(<<")"::binary, rest::binary>>, _stack), do: false

  # consume all other chars
  defp balanced_parens?(<<char::utf8, rest::binary>>, stack), do: balanced_parens?(rest, stack)
end
