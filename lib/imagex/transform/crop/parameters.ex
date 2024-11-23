# crop_size[@coordinates]
#
#   crop_size: int() <> "x" <> int()
#   coordinates: int() <> "x" <> int()
#
# crop from focus (by default: center of image) if coordinates is not supplied
defmodule Imagex.Transform.Crop.Parameters do
  import NimbleParsec

  defstruct [:width, :height, :crop_from]

  @type t :: %__MODULE__{
          width: integer(),
          height: integer(),
          crop_from: %{left: integer(), top: integer()} | :focus
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
    |> optional(
      ignore(ascii_char([?@]))
      |> tag(parsec(:dimensions), :coordinates)
    )
    |> eos()
  )

  def parse(parameters) do
    case __MODULE__.internal_parse(parameters) do
      {:ok, [crop_size: [x: width, y: height], coordinates: [x: left, y: top]], _, _, _, _} ->
        {:ok, %__MODULE__{width: width, height: height, crop_from: %{left: left, top: top}}}

      {:ok, [crop_size: [x: width, y: height]], _, _, _, _} ->
        {:ok, %__MODULE__{width: width, height: height, crop_from: :focus}}

      {:error, _, _, _, _, _} ->
        {:error, :parameter_parse_error}
    end
  end
end
