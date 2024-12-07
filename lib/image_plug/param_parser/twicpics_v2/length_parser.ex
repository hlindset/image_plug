defmodule ImagePlug.ParamParser.TwicpicsV2.LengthParser do
  alias ImagePlug.ParamParser.TwicpicsV2.NumberParser
  alias ImagePlug.ParamParser.TwicpicsV2.ArithmeticParser
  alias ImagePlug.ParamParser.TwicpicsV2.Utils

  def parse(input, pos_offset \\ 0) do
    {type, num_str} =
      case String.reverse(input) do
        "p" <> num_str -> {:percent, String.reverse(num_str)}
        "s" <> num_str -> {:scale, String.reverse(num_str)}
        num_str -> {:pixels, String.reverse(num_str)}
      end

    with {:ok, tokens} <- NumberParser.parse(num_str, pos_offset),
         {:ok, evaluated} <- ArithmeticParser.parse_and_evaluate(tokens) do
      {:ok, {type, evaluated}}
    else
      {:error, {_reason, _opts}} = error -> Utils.update_error_input(error, input)
    end
  end
end
