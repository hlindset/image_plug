defmodule ImagePlug.ParamParser.Twicpics.HSLParser do
  @moduledoc """
  Parses HSL and HSLA color strings.

  Supported formats:
    - "hsl(H S L[ / A])" or "hsla(H S L[ / A])"
    - "hsl(H,S,L)" or "hsla(H,S,L,A)" (legacy)

  H = 'none' or a float (e.g., 180, 180.5deg)
  S = 'none' or a percentage between 0% and 100%
  L = 'none' or a percentage between 0% and 100%
  A = 'none' or a float between 0 (0%) and 1 (100%)
  """

  @modern_regex ~r/
    \A
    (?:hsl|hsla)                               # Match 'hsl' or 'hsla'
    \(\s*                                      # Match opening parenthesis
    (?<h>none|\d+(\.\d+)?(deg)?)               # Capture H: 'none' or float (optional 'deg')
    \s+                                        # Require whitespace
    (?<s>none|\d+(\.\d+)?%?)                   # Capture S: 'none' or percentage
    \s+                                        # Require whitespace
    (?<l>none|\d+(\.\d+)?%?)                   # Capture L: 'none' or percentage
    (?:                                        # Optional alpha with \/
      \s*\/\s*                                 # Require '\/' with optional spaces
      (?<a>none|\d+(\.\d+)?%?)                 # Capture A: 'none', float (0–1), or percentage
    )?
    \s*\)                                      # Match closing parenthesis
    \z                                         # End of string
  /xi

  @legacy_regex ~r/
    \A
    (?:hsl|hsla)                               # Match 'hsl' or 'hsla'
    \(\s*                                      # Match opening parenthesis
    (?<h>none|\d+(\.\d+)?(deg)?)               # Capture H: 'none' or float (optional 'deg')
    ,\s*                                       # Require comma
    (?<s>none|\d+(\.\d+)?%?)                   # Capture S: 'none' or percentage
    ,\s*                                       # Require comma
    (?<l>none|\d+(\.\d+)?%?)                   # Capture L: 'none' or percentage
    (?:                                        # Optional alpha with comma
      ,\s*                                     # Require comma
      (?<a>none|\d+(\.\d+)?%?)                 # Capture A: 'none', float (0–1), or percentage
    )?
    \s*\)                                      # Match closing parenthesis
    \z                                         # End of string
  /xi

  @doc """
  Parses an HSL/HSLA string and returns a map with the parsed components.

  ## Examples

      iex> ImagePlug.ParamParser.Twicpics.HSLParser.parse("hsl(180 50% 50%)")
      {:ok, {:hsl, 180.0, 0.5, 0.5}}

      iex> ImagePlug.ParamParser.Twicpics.HSLParser.parse("hsl(none 0% 100%)")
      {:ok, {:hsl, 0.0, 0.0, 1.0}}

      iex> ImagePlug.ParamParser.Twicpics.HSLParser.parse("hsl(180, 50%, 50%)")
      {:ok, {:hsl, 180.0, 0.5, 0.5}}

      iex> ImagePlug.ParamParser.Twicpics.HSLParser.parse("hsla(160.5, 50%, 50%, 0.5)")
      {:ok, {:hsla, 160.5, 0.5, 0.5, 0.5}}

      iex> ImagePlug.ParamParser.Twicpics.HSLParser.parse("hsla(160.5, 50%, 50%, 50%)")
      {:ok, {:hsla, 160.5, 0.5, 0.5, 0.5}}

      iex> ImagePlug.ParamParser.Twicpics.HSLParser.parse("hsl(180 50% 50% / 0.5)")
      {:ok, {:hsla, 180.0, 0.5, 0.5, 0.5}}

      iex> ImagePlug.ParamParser.Twicpics.HSLParser.parse("hsl(180 40 50 / 0.6)")
      {:ok, {:hsla, 180.0, 0.4, 0.5, 0.6}}

      iex> ImagePlug.ParamParser.Twicpics.HSLParser.parse("hsl(180 50% 50% / 40%)")
      {:ok, {:hsla, 180.0, 0.5, 0.5, 0.4}}

      iex> ImagePlug.ParamParser.Twicpics.HSLParser.parse("hsl(none none none / none)")
      {:ok, {:hsl, 0.0, 0.0, 0.0}}

      iex> ImagePlug.ParamParser.Twicpics.HSLParser.parse("hsla(none, none, none, none)")
      {:ok, {:hsl, 0.0, 0.0, 0.0}}

      iex> ImagePlug.ParamParser.Twicpics.HSLParser.parse("hsl(none, none, none)")
      {:ok, {:hsl, 0.0, 0.0, 0.0}}

  """
  def parse(input, pos_offset \\ 0) when is_binary(input) do
    cond do
      String.match?(input, @modern_regex) ->
        parse_with_regex(input, @modern_regex, pos_offset)

      String.match?(input, @legacy_regex) ->
        parse_with_regex(input, @legacy_regex, pos_offset)

      true ->
        {:error, {:invalid_hsl_or_hsla_format, pos: pos_offset}}
    end
  end

  defp parse_with_regex(input, regex, pos) do
    case Regex.named_captures(regex, input) |> IO.inspect(label: input) do
      %{"h" => h, "s" => s, "l" => l, "a" => a} ->
        with {:ok, h} <- parse_value(h, :hue, pos),
             {:ok, s} <- parse_value(s, :percentage, pos),
             {:ok, l} <- parse_value(l, :percentage, pos),
             {:ok, a} <- parse_value(a, :alpha, pos) do
          if a == nil do
            {:ok, {:hsl, h, s, l}}
            else
            {:ok, {:hsla, h, s, l, a}}
          end

        else
          {:error, _reason} = error -> error
        end

      %{"h" => h, "s" => s, "l" => l} ->
        with {:ok, h} <- parse_value(h, :hue, pos),
             {:ok, s} <- parse_value(s, :percentage, pos),
             {:ok, l} <- parse_value(l, :percentage, pos) do
          {:ok, {:hsla, h, s, l}}
        else
          {:error, _reason} = error -> error
        end

      _ ->
        {:error, {:invalid_hsl_or_hsla_format, pos: pos}}
    end
  end

  defp parse_value("none", :hue, _pos), do: {:ok, 0.0}

  defp parse_value(value, :hue, pos) do
    case Float.parse(value) do
      {num, _} -> {:ok, num}
      :error -> {:error, {:invalid_hue, pos: pos}}
    end
  end

  defp parse_value("none", :percentage, _pos), do: {:ok, 0.0}

  defp parse_value(value, :percentage, pos) do
    case Float.parse(value) do
      {num, _} when num >= 0 and num <= 100 -> {:ok, num / 100}
      _ -> {:error, {:invalid_percentage, pos: pos}}
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
