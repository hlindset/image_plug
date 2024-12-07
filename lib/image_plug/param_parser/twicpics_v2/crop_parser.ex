defmodule ImagePlug.ParamParser.TwicpicsV2.CropParser do
  alias ImagePlug.ParamParser.TwicpicsV2.CoordinatesParser
  alias ImagePlug.ParamParser.TwicpicsV2.SizeParser
  alias ImagePlug.ParamParser.TwicpicsV2.Utils

  def parse(input, pos_offset \\ 0) do
    case String.split(input, "@", parts: 2) do
      [size_str, coordinates_str] ->
        with {:ok, parsed_size} <- SizeParser.parse(size_str, pos_offset),
             {:ok, parsed_coordinates} <-
               CoordinatesParser.parse(coordinates_str, pos_offset + String.length(size_str) + 1) do
          {:ok, [crop: parsed_size, crop_from: parsed_coordinates]}
        else
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end

      [size_str] ->
        case SizeParser.parse(size_str, pos_offset) do
          {:ok, parsed_size} -> {:ok, [crop: parsed_size, crop_from: :focus]}
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end
    end
  end
end
