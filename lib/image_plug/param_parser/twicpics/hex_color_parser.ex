defmodule ImagePlug.ParamParser.Twicpics.HexColorParser do
  @doc """
  Parses a hexadecimal color string and returns RGB(A) values as a tuple.

  ## Examples

      iex> ImagePlug.ParamParser.Twicpics.HexColorParser.parse_hex("76E")
      {:ok, {:rgb, 119, 102, 238}}

      iex> ImagePlug.ParamParser.Twicpics.HexColorParser.parse_hex("76E8")
      {:ok, {:rgba, 119, 102, 238, 136}}

      iex> ImagePlug.ParamParser.Twicpics.HexColorParser.parse_hex("A68040")
      {:ok, {:rgb, 166, 128, 64}}

      iex> ImagePlug.ParamParser.Twicpics.HexColorParser.parse_hex("A6804080")
      {:ok, {:rgba, 166, 128, 64, 128}}

      iex> ImagePlug.ParamParser.Twicpics.HexColorParser.parse_hex("invalid")
      {:error, :invalid_hex_format}

  """
  def parse(hex, pos) when is_binary(hex) do
    case hex |> String.trim() |> String.trim_leading("#") |> String.upcase() do
      # Match 3-character shorthand (RGB)
      <<red::binary-1, green::binary-1, blue::binary-1>> ->
        {:ok, {:rgb, expand_hex(red), expand_hex(green), expand_hex(blue)}}

      # Match 4-character shorthand (RGBA)
      <<red::binary-1, green::binary-1, blue::binary-1, alpha::binary-1>> ->
        {:ok, {:rgba, expand_hex(red), expand_hex(green), expand_hex(blue), expand_hex(alpha)}}

      # Match 6-character full (RRGGBB)
      <<red::binary-2, green::binary-2, blue::binary-2>> ->
        {:ok, {:rgb, hex_to_int(red), hex_to_int(green), hex_to_int(blue)}}

      # Match 8-character full (RRGGBBAA)
      <<red::binary-2, green::binary-2, blue::binary-2, alpha::binary-2>> ->
        {:ok, {:rgba, hex_to_int(red), hex_to_int(green), hex_to_int(blue), hex_to_int(alpha)}}

      # Invalid format
      _ ->
        {:error, {:invalid_hex_format, pos: pos}}
    end
  end

  # Helper to expand shorthand hex (e.g., "A" -> "AA") and convert to integer
  defp expand_hex(char) do
    char
    # Duplicate the single char to make it "AA"
    |> String.duplicate(2)
    |> hex_to_int()
  end

  # Helper to convert hex to integer
  defp hex_to_int(hex) do
    {int, _} = Integer.parse(hex, 16)
    int
  end
end
