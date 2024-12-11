defmodule ImagePlug.ParamParser.Twicpics.Transform.ScaleParser do
  alias ImagePlug.ParamParser.Twicpics.SizeParser
  alias ImagePlug.ParamParser.Twicpics.RatioParser
  alias ImagePlug.ParamParser.Twicpics.Utils
  alias ImagePlug.Transform.Scale.ScaleParams
  alias ImagePlug.Transform.Scale.ScaleParams.Dimensions
  alias ImagePlug.Transform.Scale.ScaleParams.AspectRatio

  @doc """
  Parses a string into a `ImagePlug.Transform.Scale.ScaleParams` struct.

  Syntax
  * `resize=<size>`
  * `resize=<ratio>`

  ## Examples
      iex> ImagePlug.ParamParser.Twicpics.Transform.ScaleParser.parse("250x25p")
      {:ok, %ImagePlug.Transform.Scale.ScaleParams{type: :dimensions, width: {:pixels, 250}, height: {:percent, 25}}}

      iex> ImagePlug.ParamParser.Twicpics.Transform.ScaleParser.parse("-x25p")
      {:ok, %ImagePlug.Transform.Scale.ScaleParams{type: :dimensions, width: :auto, height: {:percent, 25}}}

      iex> ImagePlug.ParamParser.Twicpics.Transform.ScaleParser.parse("50.5px-")
      {:ok, %ImagePlug.Transform.Scale.ScaleParams{type: :dimensions, width: {:percent, 50.5}, height: :auto}}

      iex> ImagePlug.ParamParser.Twicpics.Transform.ScaleParser.parse("50.5")
      {:ok, %ImagePlug.Transform.Scale.ScaleParams{type: :dimensions, width: {:pixels, 50.5}, height: :auto}}

      iex> ImagePlug.ParamParser.Twicpics.Transform.ScaleParser.parse("50p")
      {:ok, %ImagePlug.Transform.Scale.ScaleParams{type: :dimensions, width: {:percent, 50}, height: :auto}}

      iex> ImagePlug.ParamParser.Twicpics.Transform.ScaleParser.parse("(25*10)x(1/2)s")
      {:ok, %ImagePlug.Transform.Scale.ScaleParams{type: :dimensions, width: {:pixels, 250}, height: {:scale, 0.5}}}

      iex> ImagePlug.ParamParser.Twicpics.Transform.ScaleParser.parse("16:9")
      {:ok, %ImagePlug.Transform.Scale.ScaleParams{type: :ratio, ratio: {16, 9}}}
  """
  def parse(input, pos_offset \\ 0) do
    if String.contains?(input, ":"),
      do: parse_ratio(input, pos_offset),
      else: parse_size(input, pos_offset)
  end

  defp parse_ratio(input, pos_offset) do
    case RatioParser.parse(input, pos_offset) do
      {:ok, %{width: width, height: height}} ->
        {:ok, %ScaleParams{type: :ratio, ratio: {width, height}}}

      {:error, _reason} = error ->
        Utils.update_error_input(error, input)
    end
  end

  defp parse_size(input, pos_offset) do
    case SizeParser.parse(input, pos_offset) do
      {:ok, %{width: width, height: height}} ->
        {:ok, %ScaleParams{type: :dimensions, width: width, height: height}}

      {:error, _reason} = error ->
        Utils.update_error_input(error, input)
    end
  end
end
