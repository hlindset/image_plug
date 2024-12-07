defmodule ImagePlug.ParamParser.TwicpicsV2.SizeParser do
  alias ImagePlug.ParamParser.TwicpicsV2.LengthParser
  alias ImagePlug.ParamParser.TwicpicsV2.Utils

  def parse(input, pos_offset \\ 0) do
    case String.split(input, "x", parts: 2) do
      ["-", "-"] ->
        {:error, {:unexpected_char, pos: pos_offset + 2, expected: ["(", "[0-9]", found: "-"]}}

      ["-", height_str] ->
        case parse_and_validate(height_str, pos_offset + 2) do
          {:ok, parsed_height} -> {:ok, [width: :auto, height: parsed_height]}
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end

      [width_str, "-"] ->
        case parse_and_validate(width_str, pos_offset) do
          {:ok, parsed_width} -> {:ok, [width: parsed_width, height: :auto]}
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end

      [width_str, height_str] ->
        with {:ok, parsed_width} <- parse_and_validate(width_str, pos_offset),
             {:ok, parsed_height} <-
               parse_and_validate(height_str, pos_offset + String.length(width_str) + 1) do
          {:ok, [width: parsed_width, height: parsed_height]}
        else
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end

      [width_str] ->
        case parse_and_validate(width_str, pos_offset) do
          {:ok, parsed_width} -> {:ok, [width: parsed_width, height: :auto]}
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end
    end
  end

  defp parse_and_validate(length_str, offset) do
    case LengthParser.parse(length_str, offset) do
      {:ok, {_type, number} = parsed_length} when number > 0 ->
        {:ok, parsed_length}

      {:ok, {_type, number}} ->
        {:error, {:strictly_positive_number_required, pos: offset, found: number}}

      {:error, _reason} = error ->
        error
    end
  end
end
