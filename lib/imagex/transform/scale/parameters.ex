#  int() <> "x" <> int() -> %{width: width, height: height}
#    "*" <> "x" <> int() -> %{width: width, height: nil}
#  int() <> "x" <> "*"   -> %{width: nil,   height: height}
#  int()                 -> %{width: width, height: nil}
defmodule Imagex.Transform.Scale.Parameters do
  import NimbleParsec

  defstruct [:width, :height]

  @type t ::
          %__MODULE__{
            width: integer() | :auto,
            height: integer()
          }
          | %__MODULE__{
              width: integer(),
              height: integer() | :auto
            }

  defcombinator(:auto_size, ignore(ascii_char([?*])))
  defcombinator(:by, ignore(ascii_char([?x])))

  defcombinator(
    :explicit,
    unwrap_and_tag(integer(min: 1), :width)
    |> parsec(:by)
    |> unwrap_and_tag(integer(min: 1), :height)
  )

  defcombinator(
    :auto_height,
    unwrap_and_tag(integer(min: 1), :width) |> parsec(:by) |> parsec(:auto_size)
  )

  defcombinator(
    :auto_width,
    parsec(:auto_size) |> parsec(:by) |> unwrap_and_tag(integer(min: 1), :height)
  )

  defcombinator(:width, unwrap_and_tag(integer(min: 1), :width))

  defparsec(
    :internal_parse,
    choice([
      parsec(:explicit),
      parsec(:auto_height),
      parsec(:auto_width),
      parsec(:width)
    ])
    |> eos()
  )

  def parse(parameters) do
    case __MODULE__.internal_parse(parameters) do
      {:ok, [width: width], _, _, _, _} ->
        {:ok, %__MODULE__{width: width, height: :auto}}

      {:ok, [height: height], _, _, _, _} ->
        {:ok, %__MODULE__{width: :auto, height: height}}

      {:ok, [width: width, height: height], _, _, _, _} ->
        {:ok, %__MODULE__{width: width, height: height}}

      {:error, _, _, _, _, _} ->
        {:error, :parameter_parse_error}
    end
  end
end
