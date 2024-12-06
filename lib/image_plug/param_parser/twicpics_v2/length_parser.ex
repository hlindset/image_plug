defmodule LengthParser do
  alias ImagePlug.ParamParser.TwicpicsV2.Utils
  alias Arithmetic

  def parse(input, pos_offset \\ 0) do
    {type, num_str} =
      case String.reverse(input) do
        "p" <> num_str -> {:percent, String.reverse(num_str)}
        "s" <> num_str -> {:scale, String.reverse(num_str)}
        num_str -> {:pixels, String.reverse(num_str)}
      end

    with {:ok, tokens} <- NumberParser.parse(num_str, pos_offset),
         {:ok, evaluated} <- Arithmetic.parse_and_evaluate(tokens) do
      {:ok, {type, evaluated}}
    else
      {:error, {reason, opts}} = error -> Utils.update_error_input(error, input)
    end
  end
end

defmodule SizeParser do
  alias ImagePlug.ParamParser.TwicpicsV2.Utils

  def parse(input, pos_offset \\ 0) do
    case String.split(input, "x", parts: 2) do
      ["-", "-"] ->
        {:error, {:unexpected_char, pos: pos_offset + 2, expected: ["(", "[0-9]", found: "-"]}}

      ["-", height_str] ->
        case LengthParser.parse(height_str, pos_offset + 2) do
          {:ok, parsed_height} -> {:ok, [width: :auto, height: parsed_height]}
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end

      [width_str, "-"] ->
        case LengthParser.parse(width_str, pos_offset) do
          {:ok, parsed_width} -> {:ok, [width: parsed_width, height: :auto]}
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end

      [width_str, height_str] ->
        with {:ok, parsed_width} <- LengthParser.parse(width_str, pos_offset),
             {:ok, parsed_height} <-
               LengthParser.parse(height_str, pos_offset + String.length(width_str) + 1) do
          {:ok, [width: parsed_width, height: parsed_height]}
        else
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end

      [width_str] ->
        case LengthParser.parse(width_str, pos_offset) do
          {:ok, parsed_width} -> {:ok, [width: parsed_width, height: :auto]}
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end
    end
  end
end
