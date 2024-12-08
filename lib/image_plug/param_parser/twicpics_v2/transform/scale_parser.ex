defmodule ImagePlug.ParamParser.TwicpicsV2.Transform.ScaleParser do
  alias ImagePlug.ParamParser.TwicpicsV2.SizeParser
  alias ImagePlug.ParamParser.TwicpicsV2.RatioParser
  alias ImagePlug.ParamParser.TwicpicsV2.Utils
  alias ImagePlug.Transform.Scale.ScaleParams
  alias ImagePlug.Transform.Scale.ScaleParams.Dimensions
  alias ImagePlug.Transform.Scale.ScaleParams.AspectRatio

  def parse(input, pos_offset \\ 0) do
    if String.contains?(input, ":"),
      do: parse_ratio(input, pos_offset),
      else: parse_size(input, pos_offset)
  end

  defp parse_ratio(input, pos_offset) do
    case RatioParser.parse(input, pos_offset) do
      {:ok, %{width: width, height: height}} ->
        {:ok, %ScaleParams{method: %AspectRatio{aspect_ratio: {:ratio, width, height}}}}

      {:error, _reason} = error ->
        Utils.update_error_input(error, input)
    end
  end

  defp parse_size(input, pos_offset) do
    case SizeParser.parse(input, pos_offset) do
      {:ok, %{width: width, height: height}} ->
        {:ok, %ScaleParams{method: %Dimensions{width: width, height: height}}}

      {:error, _reason} = error ->
        Utils.update_error_input(error, input)
    end
  end
end
