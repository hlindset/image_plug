defmodule ImagePlug.ParamParser.TwicpicsV2.CoordinatesParser do
  alias ImagePlug.ParamParser.TwicpicsV2.LengthParser
  alias ImagePlug.ParamParser.TwicpicsV2.Utils

  def parse(input, pos_offset \\ 0) do
    case String.split(input, "x", parts: 2) do
      [left_str, top_str] ->
        with {:ok, parsed_left} <- parse_and_validate(left_str, pos_offset),
             {:ok, parsed_top} <-
               parse_and_validate(top_str, pos_offset + String.length(left_str) + 1) do
          {:ok, %{left: parsed_left, top: parsed_top}}
        else
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end

      [left_str] ->
        # this is an invalid coordinate!
        #
        # attempt to parse string to get error messages for number parsing.
        # if it suceeds, complain that the second dimension that's missing
        case parse_and_validate(left_str, pos_offset) do
          {:ok, _} ->
            Utils.unexpected_value_error(pos_offset + String.length(left_str), ["x"], :eoi)
            |> Utils.update_error_input(input)

          {:error, _} = error ->
            Utils.update_error_input(error, input)
        end
    end
  end

  defp parse_and_validate(length_str, pos_offset) do
    case LengthParser.parse(length_str, pos_offset) do
      {:ok, {_type, number} = parsed_length} when number >= 0 ->
        {:ok, parsed_length}

      {:ok, {_type, number}} ->
        {:error, {:positive_number_required, pos: pos_offset, found: number}}

      {:error, _reason} = error ->
        error
    end
  end
end
