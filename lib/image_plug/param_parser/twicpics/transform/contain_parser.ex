defmodule ImagePlug.ParamParser.Twicpics.Transform.ContainParser do
  alias ImagePlug.ParamParser.Twicpics.SizeParser
  alias ImagePlug.ParamParser.Twicpics.RatioParser
  alias ImagePlug.ParamParser.Twicpics.Utils
  alias ImagePlug.Transform.Contain.ContainParams

  def parse(input, pos_offset \\ 0) do
    case SizeParser.parse(input, pos_offset) do
      {:ok, %{width: width, height: height}} ->
        {:ok, %ContainParams{width: width, height: height}}

      {:error, _reason} = error ->
        Utils.update_error_input(error, input)
    end
  end
end
