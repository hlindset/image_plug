# crop_size[@coordinates]
#
#   crop_size: int() <> "x" <> int()
#   coordinates: int() <> "x" <> int()
#
# crop from focus (by default: center of image) if coordinates is not supplied
defmodule Imagex.Transform.Crop.Parameters do
  import NimbleParsec

  import Imagex.Parameters.Shared

  defstruct [:width, :height, :crop_from]

  @type int_or_pct() :: {:int, integer()} | {:pct, integer()}
  @type t :: %__MODULE__{
          width: int_or_pct(),
          height: int_or_pct(),
          crop_from: :focus | %{left: int_or_pct(), top: int_or_pct()}
        }

  defparsecp(
    :internal_parse,
    tag(parsec(:dimension), :crop_size)
    |> optional(
      ignore(ascii_char([?@]))
      |> tag(parsec(:dimension), :coordinates)
    )
    |> eos()
  )

  def parse(parameters) do
    case internal_parse(parameters) do
      {:ok, [crop_size: [x: width, y: height], coordinates: [x: left, y: top]], _, _, _, _} ->
        {:ok, %__MODULE__{width: width, height: height, crop_from: %{left: left, top: top}}}

      {:ok, [crop_size: [x: width, y: height]], _, _, _, _} ->
        {:ok, %__MODULE__{width: width, height: height, crop_from: :focus}}

      {:error, msg, _, _, _, _} ->
        {:error, {:parameter_parse_error, msg, parameters}}
    end
  end
end
