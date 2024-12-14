defmodule ImagePlug.ParamParser.Twicpics.Transform.CoverMaxParser do
  alias ImagePlug.ParamParser.Twicpics.SizeParser
  alias ImagePlug.ParamParser.Twicpics.RatioParser
  alias ImagePlug.ParamParser.Twicpics.Utils
  alias ImagePlug.Transform.Cover.CoverParams

  @doc """
  Parses a string into a `ImagePlug.Transform.Cover.CoverParams` struct.

  Syntax:
  * `cover-max=<size>`

  ## Examples

      iex> ImagePlug.ParamParser.Twicpics.Transform.CoverMaxParser.parse("250x25.5")
      {:ok, %ImagePlug.Transform.Cover.CoverParams{width: {:pixels, 250}, height: {:pixels, 25.5}, constraint: :max}}
  """

  def parse(input, pos_offset \\ 0) do
    case SizeParser.parse(input, pos_offset) do
      {:ok, %{width: width, height: height}} ->
        {:ok, %CoverParams{type: :dimensions, width: width, height: height, constraint: :max}}

      {:error, _reason} = error ->
        Utils.update_error_input(error, input)
    end
  end
end
