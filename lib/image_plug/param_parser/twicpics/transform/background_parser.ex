defmodule ImagePlug.ParamParser.Twicpics.Transform.BackgroundParser do
  alias ImagePlug.ParamParser.Twicpics.CoordinatesParser
  alias ImagePlug.ParamParser.Twicpics.Utils
  alias ImagePlug.ParamParser.Twicpics.HSLParser
  alias ImagePlug.ParamParser.Twicpics.RGBParser
  alias ImagePlug.ParamParser.Twicpics.HexColorParser

  alias ImagePlug.Transform.Background.BackgroundParams

  @delimiter "+"
  @css_colors Image.Color.color_map()

  @doc """
  Parses a string into a `ImagePlug.Transform.Background.BackgroundParams` struct.
  """
  def parse(input, pos_offset \\ 0) do
    # TODO: use reduce_while to fail on first error
    items =
      split_with_offset(input)
      |> Enum.map(fn {item, local_offset} ->
        to_color(maybe_split_alpha(item), pos_offset + local_offset)
      end)

    IO.inspect(items)

    {:ok, %BackgroundParams{backgrounds: []}}
  end

  defp split_with_offset(string) do
    string
    |> String.split(@delimiter)
    |> Enum.reduce({[], 0}, fn part, {acc, offset} ->
      updated_acc = acc ++ [{part, offset}]
      new_offset = offset + String.length(part) + String.length(@delimiter)
      {updated_acc, new_offset}
    end)
    # Extract the result list
    |> elem(0)
  end

  def maybe_split_alpha(item) do
    # todo: only split if last part is "\.\d+"
    case String.split(item, ".", parts: 2) do
      [color, alpha] -> {color, alpha}
      [color] -> {color, 100}
    end
  end

  def to_color({item, alpha}, _pos_offset) when is_map_key(@css_colors, item) do
    css_color = Map.get(@css_colors, item)
    [r, g, b] = Keyword.get(css_color, :rgb)
    {:ok, {:rgb, r, g, b}}
  end

  def to_color({item, alpha}, pos) do
    cond do
      Regex.match?(~r/^hsla?\(/i, item) -> HSLParser.parse(item, pos)
      Regex.match?(~r/^rgba?\(/i, item) -> RGBParser.parse(item, pos)
      Regex.match?(~r/^#?[a-f0-9]{3,8}$/i, item) -> HexColorParser.parse(item, pos)
      item == "blur" -> {:ok, {:blur, 50.0}}
      true -> {:error, {:invalid_background, pos: pos}}
    end
  end
end
