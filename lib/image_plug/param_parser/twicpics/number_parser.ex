defmodule ImagePlug.ParamParser.Twicpics.NumberParser do
  alias ImagePlug.ParamParser.Twicpics.ArithmeticTokenizer
  alias ImagePlug.ParamParser.Twicpics.ArithmeticParser

  def parse(input, pos_offset \\ 0) do
    with {:ok, tokens} <- ArithmeticTokenizer.tokenize(input, pos_offset),
         {:ok, evaluated} <- ArithmeticParser.parse_and_evaluate(tokens) do
      {:ok, evaluated}
    else
      {:error, {_reason, _opts}} = error -> error
    end
  end
end
