defmodule ImagePlug.ParamParser.Twicpics.Transform.CropParser do
  alias ImagePlug.ParamParser.Twicpics.CoordinatesParser
  alias ImagePlug.ParamParser.Twicpics.SizeParser
  alias ImagePlug.ParamParser.Twicpics.Utils
  alias ImagePlug.Transform.Crop.CropParams

  @doc """
  Parses a string into a `ImagePlug.Transform.Crop.CropParams` struct.

  Syntax:
  * `crop=<crop size>`
  * `crop=<crop size>@<coordinates>`

  ## Examples
      iex> ImagePlug.ParamParser.Twicpics.Transform.CropParser.parse("250x25p")
      {:ok, %ImagePlug.Transform.Crop.CropParams{width: {:pixels, 250}, height: {:percent, 25}, crop_from: :focus}}

      iex> ImagePlug.ParamParser.Twicpics.Transform.CropParser.parse("20px25@10x50.1p")
      {:ok, %ImagePlug.Transform.Crop.CropParams{width: {:percent, 20}, height: {:pixels, 25}, crop_from: %{left: {:pixels, 10}, top: {:percent, 50.1}}}}
  """
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
