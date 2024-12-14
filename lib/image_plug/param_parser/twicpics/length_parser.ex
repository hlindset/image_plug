defmodule ImagePlug.ParamParser.Twicpics.LengthParser do
  alias ImagePlug.ParamParser.Twicpics.NumberParser
  alias ImagePlug.ParamParser.Twicpics.Utils

  def parse(input, pos_offset \\ 0) do
    {type, number_str} =
      case String.reverse(input) do
        "p" <> number_str -> {:percent, String.reverse(number_str)}
        "s" <> number_str -> {:scale, String.reverse(number_str)}
        number_str -> {:pixels, String.reverse(number_str)}
      end

    case NumberParser.parse(number_str, pos_offset) do
      {:ok, number} -> {:ok, {type, number}}
      {:error, _reason} = error -> Utils.update_error_input(error, input)
    end
  end
end
