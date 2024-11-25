defmodule Imagex.Transform.Crop.Parameters do
  @doc """
  The parsed parameters used by `Imagex.Transform.Crop`.
  """

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

  @doc """
  Parses a string into a`Imagex.Transform.Crop.Parameters` struct.

  Returns a `Imagex.Transform.Crop.Parameters` struct.

  ## Format

  ```
  <width>x<height>[@<left>x<top>]
  ```

  ## Units

  Type      | Format
  --------- | ------------
  `pixel`   | `<int>`
  `percent` | `<float>p`

  ## Examples

      iex> Imagex.Transform.Crop.Parameters.parse("250x25p")
      {:ok, %Imagex.Transform.Crop.Parameters{width: {:int, 250}, height: {:pct, 25.0}, crop_from: :focus}}

      iex> Imagex.Transform.Crop.Parameters.parse("20px25@10x50.1p")
      {:ok, %Imagex.Transform.Crop.Parameters{width: {:pct, 20.0}, height: {:int, 25}, crop_from: %{left: {:int, 10}, top: {:pct, 50.1}}}}
  """
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
