defmodule ImagePlug.ParamParser.Twicpics.Transform.ContainMaxParser do
  alias ImagePlug.ParamParser.Twicpics.SizeParser
  alias ImagePlug.ParamParser.Twicpics.RatioParser
  alias ImagePlug.ParamParser.Twicpics.Utils
  alias ImagePlug.Transform.Contain.ContainParams

  @doc """
  Parses a string into a `ImagePlug.Transform.Contain.ContainParams` struct.

  Syntax:
  * `contain-max=<size>`

  ## Examples

      iex> ImagePlug.ParamParser.Twicpics.Transform.ContainMaxParser.parse("250x25.5")
      {:ok, %ImagePlug.Transform.Contain.ContainParams{type: :dimensions, width: {:pixels, 250}, height: {:pixels, 25.5}, constraint: :max, letterbox: false}}
  """

  def parse(input, pos_offset \\ 0) do
    case SizeParser.parse(input, pos_offset) do
      {:ok, %{width: width, height: height}} ->
        {:ok,
         %ContainParams{
           type: :dimensions,
           width: width,
           height: height,
           constraint: :max,
           letterbox: false
         }}

      {:error, _reason} = error ->
        Utils.update_error_input(error, input)
    end
  end
end
