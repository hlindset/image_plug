defmodule ImagePlug.ParamParser.Twicpics.Transform.FocusParser do
  alias ImagePlug.ParamParser.Twicpics.CoordinatesParser
  alias ImagePlug.ParamParser.Twicpics.Utils

  alias ImagePlug.Transform.Focus.FocusParams

  @anchors %{
    "center" => {:anchor, :center, :center},
    "bottom" => {:anchor, :center, :bottom},
    "bottom-left" => {:anchor, :left, :bottom},
    "bottom-right" => {:anchor, :right, :bottom},
    "left" => {:anchor, :left, :center},
    "top" => {:anchor, :center, :top},
    "top-left" => {:anchor, :left, :top},
    "top-right" => {:anchor, :right, :top},
    "right" => {:anchor, :right, :center}
  }

  def parse(input, pos_offset \\ 0) do
    if String.contains?(input, "x"),
      do: parse_coordinates(input, pos_offset),
      else: parse_anchor_string(input, pos_offset)
  end

  defp parse_coordinates(input, pos_offset) do
    case CoordinatesParser.parse(input, pos_offset) do
      {:ok, %{left: left, top: top}} ->
        {:ok, %FocusParams{type: {:coordinate, left, top}}}

      {:error, _reason} = error ->
        Utils.update_error_input(error, input)
    end
  end

  defp parse_anchor_string(input, pos_offset) do
    case Map.get(@anchors, input) do
      {:anchor, _, _} = anchor ->
        {:ok, %FocusParams{type: anchor}}

      _ ->
        Utils.unexpected_value_error(pos_offset, Map.keys(@anchors), input)
        |> Utils.update_error_input(input)
    end
  end
end
