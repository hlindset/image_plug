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
    result =
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

defmodule CoordinatesParser do
  alias ImagePlug.ParamParser.TwicpicsV2.Utils

  def parse(input, pos_offset \\ 0) do
    result =
      case String.split(input, "x", parts: 2) do
        [left_str, top_str] ->
          with {:ok, parsed_left} <- parse_and_validate(left_str, pos_offset),
               {:ok, parsed_top} <-
                 parse_and_validate(top_str, pos_offset + String.length(left_str) + 1) do
            {:ok, [left: parsed_left, top: parsed_top]}
          else
            {:error, _reason} = error -> Utils.update_error_input(error, input)
          end
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
