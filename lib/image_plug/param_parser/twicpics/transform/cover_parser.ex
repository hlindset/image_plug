defmodule ImagePlug.ParamParser.Twicpics.Transform.CoverParser do
  alias ImagePlug.ParamParser.Twicpics.SizeParser
  alias ImagePlug.ParamParser.Twicpics.RatioParser
  alias ImagePlug.ParamParser.Twicpics.Utils
  alias ImagePlug.Transform.Cover.CoverParams

  @doc """
  Parses a string into a `ImagePlug.Transform.Cover.CoverParams` struct.

  Syntax
  * `cover=<size>`
  * `cover=<ratio>`

  ## Examples

      iex> ImagePlug.ParamParser.Twicpics.Transform.CoverParser.parse("250x25.5")
      {:ok, %ImagePlug.Transform.Cover.CoverParams{type: :dimensions, width: {:pixels, 250}, height: {:pixels, 25.5}, constraint: :none}}

      iex> ImagePlug.ParamParser.Twicpics.Transform.CoverParser.parse("16:9")
      {:ok, %ImagePlug.Transform.Cover.CoverParams{type: :ratio, ratio: {16, 9}, constraint: :none}}
  """

  def parse(input, pos_offset \\ 0) do
    if String.contains?(input, ":"),
      do: parse_ratio(input, pos_offset),
      else: parse_size(input, pos_offset)
  end

  defp parse_ratio(input, pos_offset) do
    case RatioParser.parse(input, pos_offset) do
      {:ok, %{width: width, height: height}} ->
        {:ok, %CoverParams{type: :ratio, ratio: {width, height}}, constraint: :none}

      {:error, _reason} = error ->
        Utils.update_error_input(error, input)
    end
  end

  defp parse_size(input, pos_offset) do
    case SizeParser.parse(input, pos_offset) do
      {:ok, %{width: width, height: height}} ->
        {:ok, %CoverParams{type: :dimensions, width: width, height: height, constraint: :none}}

      {:error, _reason} = error ->
        Utils.update_error_input(error, input)
    end
  end
end
