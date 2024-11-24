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
  defcombinator(:pct_size, float |> ignore(percent_char) |> tag(:pct))
  defcombinator(:auto_size, ignore(auto_size_char) |> tag(:auto))

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

  defp parse_number({:int, int}), do: {:int, int}
  defp parse_number({:pct, [int]}), do: {:pct, int}

  defp parse_number({:pct, [int_part, 46, decimal_part] = float_list}) do
    case Float.parse("#{int_part}.#{decimal_part}") do
      {float, _} -> {:pct, float}
    end
  end

  def parse(parameters) do
    case __MODULE__.internal_parse(parameters) do
      {:ok, [width: width], _, _, _, _} ->
        {:ok, %__MODULE__{width: parse_number(width), height: :auto}}

      {:ok, [width: width, height: {:auto, _}], _, _, _, _} ->
        {:ok, %__MODULE__{width: parse_number(width), height: :auto}}

      {:ok, [width: {:auto, _}, height: height], _, _, _, _} ->
        {:ok, %__MODULE__{width: :auto, height: parse_number(height)}}

      {:ok, [width: width, height: height], _, _, _, _} ->
        {:ok, %__MODULE__{width: parse_number(width), height: parse_number(height)}}

      {:error, msg, _, _, _, _} ->
        {:error, {:parameter_parse_error, msg, parameters}}
    end
  end
end
