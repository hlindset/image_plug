defmodule ImagePlug.ParamParser.TwicpicsV2.CoordinatesParser do
  alias ImagePlug.ParamParser.TwicpicsV2.LengthParser
  alias ImagePlug.ParamParser.TwicpicsV2.Utils

  def parse(input, pos_offset \\ 0) do
    case String.split(input, "x", parts: 2) do
      [left_str, top_str] ->
        with {:ok, parsed_left} <- parse_and_validate(left_str, pos_offset),
             {:ok, parsed_top} <-
               parse_and_validate(top_str, pos_offset + String.length(left_str) + 1) do
          {:ok, [left: parsed_left, top: parsed_top]}
        else
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end

      [""] ->
        {:error, {:unexpected_eoi, pos: pos_offset}}

      _ ->
        {:error, {:unexpected_token, pos: pos_offset}}
    end
  end

  defp parse_and_validate(length_str, offset) do
    case LengthParser.parse(length_str, offset) do
      {:ok, {_type, number} = parsed_length} when number >= 0 -> {:ok, parsed_length}
      {:ok, {_type, number}} -> {:error, {:positive_number_required, pos: offset, found: number}}
      {:error, _reason} = error -> error
    end
  end
end
