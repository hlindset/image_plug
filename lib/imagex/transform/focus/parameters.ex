# coordinates: int() <> "x" <> int()
defmodule Imagex.Transform.Focus.Parameters do
  import NimbleParsec

  defstruct [:left, :top]

  @type t :: %__MODULE__{
          left: integer(),
          top: integer()
        }

  defcombinator(
    :dimensions,
    unwrap_and_tag(integer(min: 1), :x)
    |> ignore(ascii_char([?x]))
    |> unwrap_and_tag(integer(min: 1), :y)
  )

  defparsec(
    :internal_parse,
    tag(parsec(:dimensions), :crop_size)
    |> eos()
  )

  def parse(parameters) do
    case __MODULE__.internal_parse(parameters) do
      {:ok, [crop_size: [x: left, y: top]], _, _, _, _} ->
        {:ok, %__MODULE__{left: left, top: top}}

      {:error, _, _, _, _, _} ->
        {:error, :parameter_parse_error}
    end
  end
end
