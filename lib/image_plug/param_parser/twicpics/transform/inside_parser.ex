defmodule ImagePlug.ParamParser.Twicpics.Transform.InsideParser do
  alias ImagePlug.ParamParser.Twicpics.SizeParser
  alias ImagePlug.ParamParser.Twicpics.RatioParser
  alias ImagePlug.ParamParser.Twicpics.Utils
  alias ImagePlug.Transform.Contain.ContainParams

  @doc """
  Parses a string into a `ImagePlug.Transform.Contain.ContainParams` struct.

  Syntax:
  * `inside=<size>`
  * `inside=<ratio>`

  ## Examples

  iex> ImagePlug.ParamParser.Twicpics.Transform.InsideParser.parse("250x25.5p")
  {:ok, %ImagePlug.Transform.Contain.ContainParams{type: :dimensions, width: {:pixels, 250}, height: {:percent, 25.5}, constraint: :none, letterbox: true}}

  iex> ImagePlug.ParamParser.Twicpics.Transform.InsideParser.parse("1.5:2")
  {:ok, %ImagePlug.Transform.Contain.ContainParams{type: :ratio, ratio: {1.5, 2}, letterbox: true}}
  """

  def parse(input, pos_offset \\ 0) do
    if String.contains?(input, ":"),
      do: parse_ratio(input, pos_offset),
      else: parse_size(input, pos_offset)
  end

  defp parse_ratio(input, pos_offset) do
    case RatioParser.parse(input, pos_offset) do
      {:ok, %{width: width, height: height}} ->
        {:ok, %ContainParams{type: :ratio, ratio: {width, height}, letterbox: true}}

      {:error, _reason} = error ->
        Utils.update_error_input(error, input)
    end
  end

  defp parse_size(input, pos_offset) do
    case SizeParser.parse(input, pos_offset) do
      {:ok, %{width: width, height: height}} ->
        {:ok,
         %ContainParams{
           type: :dimensions,
           width: width,
           height: height,
           constraint: :none,
           letterbox: true
         }}

      {:error, _reason} = error ->
        Utils.update_error_input(error, input)
    end
  end
end
