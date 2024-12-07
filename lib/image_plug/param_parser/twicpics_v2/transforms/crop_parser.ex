defmodule ImagePlug.ParamParser.TwicpicsV2.Transforms.CropParser do
  alias ImagePlug.ParamParser.TwicpicsV2.CoordinatesParser
  alias ImagePlug.ParamParser.TwicpicsV2.SizeParser
  alias ImagePlug.ParamParser.TwicpicsV2.Utils
  alias ImagePlug.Transform.Crop.CropParams

  def parse(input, pos_offset \\ 0) do
    case String.split(input, "@", parts: 2) do
      [size_str, coordinates_str] ->
        with {:ok, parsed_size} <- SizeParser.parse(size_str, pos_offset),
             {:ok, parsed_coordinates} <-
               CoordinatesParser.parse(coordinates_str, pos_offset + String.length(size_str) + 1) do
          {:ok,
           %CropParams{
             width: parsed_size.width,
             height: parsed_size.height,
             crop_from: %{
               left: parsed_coordinates.left,
               top: parsed_coordinates.top
             }
           }}
        else
          {:error, _reason} = error -> Utils.update_error_input(error, input)
        end

      [size_str] ->
        case SizeParser.parse(size_str, pos_offset) do
          {:ok, parsed_size} ->
            {:ok,
             %CropParams{
               width: parsed_size.width,
               height: parsed_size.height,
               crop_from: :focus
             }}

          {:error, _reason} = error ->
            Utils.update_error_input(error, input)
        end
    end
  end
end
