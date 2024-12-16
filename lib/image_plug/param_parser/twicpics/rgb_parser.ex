defmodule ImagePlug.ParamParser.Twicpics.RGBParser do
  @moduledoc """
  Parses RGB and RGBA color strings.

  Supported formats:
    - "rgb(H S L[ / A])" or "rgba(H S L[ / A])"
    - "rgb(H,S,L)" or "rgba(H,S,L,A)" (legacy)

  H = 'none' or a float (e.g., 180, 180.5deg)
  S = 'none' or a percentage between 0% and 100%
  L = 'none' or a percentage between 0% and 100%
  A = 'none' or a float between 0 (0%) and 1 (100%)
  """

  @modern_regex ~r/
    \A
    (?:rgb|rgba)                               # Match 'rgb' or 'rgba'
    \(\s*                                      # Match opening parenthesis
    (?<r>none|\d+(\.\d+)?%?)                   # Capture H: 'none' or float (optional 'deg')
    \s+                                        # Require whitespace
    (?<g>none|\d+(\.\d+)?%?)                   # Capture S: 'none' or percentage
    \s+                                        # Require whitespace
    (?<b>none|\d+(\.\d+)?%?)                   # Capture L: 'none' or percentage
    (?:                                        # Optional alpha with \/
      \s*\/\s*                                 # Require '\/' with optional spaces
      (?<a>none|\d+(\.\d+)?%?)                 # Capture A: 'none', float (0–1), or percentage
    )?
    \s*\)                                      # Match closing parenthesis
    \z                                         # End of string
  /xi

  @legacy_regex ~r/
    \A
    (?:rgb|rgba)                               # Match 'rgb' or 'rgba'
    \(\s*                                      # Match opening parenthesis
    (?<r>none|\d+(\.\d+)?%?)                   # Capture H: 'none' or float (optional 'deg')
    ,\s*                                       # Require comma
    (?<g>none|\d+(\.\d+)?%?)                   # Capture S: 'none' or percentage
    ,\s*                                       # Require comma
    (?<b>none|\d+(\.\d+)?%?)                   # Capture L: 'none' or percentage
    (?:                                        # Optional alpha with comma
      ,\s*                                     # Require comma
      (?<a>none|\d+(\.\d+)?%?)                 # Capture A: 'none', float (0–1), or percentage
    )?
    \s*\)                                      # Match closing parenthesis
    \z                                         # End of string
  /xi

  @doc """
  Parses an RGB/RGBA string and returns a map with the parsed components.

  ## Examples

      iex> ImagePlug.ParamParser.Twicpics.RGBParser.parse("rgb(50% 50% 50%)")
      {:ok, {:rgb, 128, 128, 128}}

      iex> ImagePlug.ParamParser.Twicpics.RGBParser.parse("rgb(none 0% 100%)")
      {:ok, {:rgb, 0, 0, 255}}

      iex> ImagePlug.ParamParser.Twicpics.RGBParser.parse("rgb(180, 50%, 50%)")
      {:ok, {:rgb, 180, 128, 128}}

      iex> ImagePlug.ParamParser.Twicpics.RGBParser.parse("rgba(160.5, 50%, 50%, 0.5)")
      {:ok, {:rgba, 161, 128, 128, 0.5}}

      iex> ImagePlug.ParamParser.Twicpics.RGBParser.parse("rgba(160.5, 50%, 50%, 50%)")
      {:ok, {:rgba, 161, 128, 128, 0.5}}

      iex> ImagePlug.ParamParser.Twicpics.RGBParser.parse("rgb(180 50% 50% / 0.5)")
      {:ok, {:rgba, 180, 128, 128, 0.5}}

      iex> ImagePlug.ParamParser.Twicpics.RGBParser.parse("rgb(180 40 50 / 0.6)")
      {:ok, {:rgba, 180, 40, 50, 0.6}}

      iex> ImagePlug.ParamParser.Twicpics.RGBParser.parse("rgb(180 50% 50% / 40%)")
      {:ok, {:rgba, 180, 128, 128, 0.4}}

      iex> ImagePlug.ParamParser.Twicpics.RGBParser.parse("rgb(none none none / none)")
      {:ok, {:rgb, 0, 0, 0}}

      iex> ImagePlug.ParamParser.Twicpics.RGBParser.parse("rgba(none, none, none, none)")
      {:ok, {:rgb, 0, 0, 0}}

      iex> ImagePlug.ParamParser.Twicpics.RGBParser.parse("rgb(none, none, none)")
      {:ok, {:rgb, 0, 0, 0}}

  """
  def parse(input, pos_offset \\ 0) when is_binary(input) do
    cond do
      String.match?(input, @modern_regex) ->
        parse_with_regex(input, @modern_regex, pos_offset)

      String.match?(input, @legacy_regex) ->
        parse_with_regex(input, @legacy_regex, pos_offset)

      true ->
        {:error, {:invalid_rgb_or_rgba_format, pos: pos_offset}}
    end
  end

  defp parse_with_regex(input, regex, pos) do
    case Regex.named_captures(regex, input) |> IO.inspect(label: input) do
      %{"r" => r, "g" => g, "b" => b, "a" => a} ->
        with {:ok, r} <- parse_value(r, :color, pos),
             {:ok, g} <- parse_value(g, :color, pos),
             {:ok, b} <- parse_value(b, :color, pos),
             {:ok, a} <- parse_value(a, :alpha, pos) do
               if a == nil do
                 {:ok, {:rgb, r, g, b}}
                 else
                 {:ok, {:rgba, r, g, b, a}}
               end

        else
          {:error, _reason} = error -> error
        end

      %{"r" => r, "g" => g, "b" => b} ->
        with {:ok, r} <- parse_value(r, :color, pos),
             {:ok, g} <- parse_value(g, :color, pos),
             {:ok, b} <- parse_value(b, :color, pos) do
          {:ok, {:rgb, r, g, b}}
        else
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, {:invalid_rgb_or_rgba_format, pos: pos}}
    end
  end

  defp parse_value("none", :color, _pos), do: {:ok, 0}

  defp parse_value(value, :color, pos) do
    case Float.parse(value) do
      {num, "%"} when num >= 0 and num <= 100 -> {:ok, round(255 * (num / 100))}
      {num, _} when num >= 0 and num <= 255 -> {:ok, round(num)}
      _ -> {:error, {:invalid_color_value, pos: pos}}
    end
  end

  defp parse_value(nil, :alpha, _pos), do: {:ok, nil}
  defp parse_value("", :alpha, _pos), do: {:ok, nil}
  defp parse_value("none", :alpha, _pos), do: {:ok, nil}

  defp parse_value(value, :alpha, pos) do
    case Float.parse(value) do
      {num, "%"} when num >= 0 and num <= 100 -> {:ok, num / 100}
      {num, _} when num >= 0 and num <= 1 -> {:ok, num}
      _ -> {:error, {:invalid_alpha, pos: pos}}
    end
  end
end
