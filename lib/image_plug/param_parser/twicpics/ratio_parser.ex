defmodule ImagePlug.ParamParser.Twicpics.RatioParser do
  alias ImagePlug.ParamParser.Twicpics.NumberParser
  alias ImagePlug.ParamParser.Twicpics.ArithmeticParser
  alias ImagePlug.ParamParser.Twicpics.Utils

  def parse(input, pos_offset \\ 0) do
    case String.split(input, ":", parts: 2) do
      [width_str, height_str] ->
        with {:ok, parsed_width} <- parse_and_validate(width_str, pos_offset),
             {:ok, parsed_height} <-
               parse_and_validate(height_str, pos_offset + String.length(width_str) + 1) do
          {:ok, %{width: parsed_width, height: parsed_height}}
        else
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end

      [width_str] ->
        # this is an invalid ratio!
        #
        # attempt to parse string to get error messages for number parsing.
        # if it suceeds, complain that the second component that's missing
        case parse_and_validate(width_str, pos_offset) do
          {:ok, _} ->
            Utils.unexpected_value_error(pos_offset + String.length(width_str), [":"], :eoi)
            |> Utils.update_error_input(input)

          {:error, _} = error ->
            Utils.update_error_input(error, input)
        end
    end
  end

  defp parse_and_validate(num_str, pos_offset) do
    with {:ok, tokens} <- NumberParser.parse(num_str, pos_offset),
         {:ok, evaluated} <- ArithmeticParser.parse_and_evaluate(tokens) do
      if evaluated > 0 do
        {:ok, evaluated}
      else
        {:error, {:positive_number_required, pos: pos_offset, found: evaluated}}
      end
    else
      {:error, {_reason, _opts}} = error -> error
    end
  end
end
