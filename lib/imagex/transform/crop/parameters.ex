# crop_size[@coordinates]
#
#   crop_size: int() <> "x" <> int()
#   coordinates: int() <> "x" <> int()
#
# crop from focus (by default: center of image) if coordinates is not supplied
defmodule Imagex.Transform.Crop.Parameters do
  import NimbleParsec

  defstruct [:width, :height, :crop_from]

  @type int_or_pct() :: {:int, integer()} | {:pct, integer()}
  @type t :: %__MODULE__{
          width: int_or_pct(),
          height: int_or_pct(),
          crop_from: :focus | %{left: int_or_pct(), top: int_or_pct()}
        }

  percent_char = ascii_char([?p])
  dot_char = ascii_char([?.])
  float = integer(min: 1) |> optional(dot_char |> ascii_string([?0..?9], min: 1))
  integer = integer(min: 1) |> lookahead_not(choice([dot_char, percent_char]))

  defcombinator(:int_size, integer |> unwrap_and_tag(:int))
  defcombinator(:pct_size, float |> ignore(percent_char) |> tag(:pct))

  int_or_pct =
    choice([
      parsec(:int_size),
      parsec(:pct_size)
    ])

  defcombinator(
    :dimensions,
    unwrap_and_tag(int_or_pct, :x)
    |> ignore(ascii_char([?x]))
    |> unwrap_and_tag(int_or_pct, :y)
  )

  defparsec(
    :internal_parse,
    tag(parsec(:dimensions), :crop_size)
    |> optional(
      ignore(ascii_char([?@]))
      |> tag(parsec(:dimensions), :coordinates)
    )
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
      {:ok, [crop_size: [x: width, y: height], coordinates: [x: left, y: top]], _, _, _, _} ->
        {:ok,
         %__MODULE__{
           width: parse_number(width),
           height: parse_number(height),
           crop_from: %{left: parse_number(left), top: parse_number(top)}
         }}

      {:ok, [crop_size: [x: width, y: height]], _, _, _, _} ->
        {:ok,
         %__MODULE__{width: parse_number(width), height: parse_number(height), crop_from: :focus}}

      {:error, msg, _, _, _, _} = error ->
        {:error, {:parameter_parse_error, msg, parameters}}
    end
  end
end
