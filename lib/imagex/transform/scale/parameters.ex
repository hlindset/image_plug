#  int() <> "x" <> int() -> %{width: width, height: height}
#    "*" <> "x" <> int() -> %{width: :auto, height: height}
#  int() <> "x" <> "*"   -> %{width: width, height: :auto}
#  int()                 -> %{width: width, height: :auto}
defmodule Imagex.Transform.Scale.Parameters do
  import NimbleParsec

  defstruct [:width, :height]

  @type int_or_pct() :: {:int, integer()} | {:pct, integer()}

  @type t ::
          %__MODULE__{
            width: int_or_pct() | :auto,
            height: int_or_pct()
          }
          | %__MODULE__{
              width: int_or_pct(),
              height: int_or_pct() | :auto
            }

  percent_char = ascii_char([?p])
  dot_char = ascii_char([?.])
  auto_size_char = ascii_char([?*])
  float = integer(min: 1) |> optional(dot_char |> ascii_string([?0..?9], min: 1))
  integer = integer(min: 1) |> lookahead_not(choice([dot_char, percent_char]))

  defcombinator(:int_size, integer |> unwrap_and_tag(:int))

  defcombinator(
    :pct_size,
    float
    |> ignore(percent_char)
    |> tag(:pct)
    |> post_traverse(:maybe_parse_pct_float)
  )

  defcombinator(
    :auto_size,
    ignore(auto_size_char)
    |> tag(:auto)
    |> post_traverse(:post_traverse_auto_size)
  )

  int_or_pct =
    choice([
      parsec(:int_size),
      parsec(:pct_size)
    ])

  auto_width =
    unwrap_and_tag(choice([int_or_pct, parsec(:auto_size)]), :width)
    |> ignore(ascii_char([?x]))
    |> unwrap_and_tag(int_or_pct, :height)

  auto_height =
    unwrap_and_tag(int_or_pct, :width)
    |> ignore(ascii_char([?x]))
    |> unwrap_and_tag(choice([int_or_pct, parsec(:auto_size)]), :height)

  simple = unwrap_and_tag(int_or_pct, :width)

  defcombinator(
    :dimensions,
    choice([auto_width, auto_height, simple])
  )

  defparsec(
    :internal_parse,
    parsec(:dimensions)
    |> eos()
  )

  defp post_traverse_auto_size(rest, [auto: []], context, _line, _offset) do
    {rest, [:auto], context}
  end

  defp maybe_parse_pct_float(rest, [pct: [int_part, 46, decimal_part]], context, _line, _offset) do
    case Float.parse("#{int_part}.#{decimal_part}") do
      {float, _} -> {rest, [pct: float], context}
      _ -> {:error, :invalid_float}
    end
  end

  defp maybe_parse_pct_float(rest, [pct: [int]], context, _line, _offset) do
    {rest, [pct: int], context}
  end

  def parse(parameters) do
    case __MODULE__.internal_parse(parameters) do
      {:ok, [width: width], _, _, _, _} ->
        {:ok, %__MODULE__{width: width, height: :auto}}

      {:ok, [width: width, height: height], _, _, _, _} ->
        {:ok, %__MODULE__{width: width, height: height}}

      {:error, msg, _, _, _, _} ->
        {:error, {:parameter_parse_error, msg, parameters}}
    end
  end
end
