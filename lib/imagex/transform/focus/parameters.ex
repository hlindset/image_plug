defmodule Imagex.Transform.Focus.Parameters do
  import NimbleParsec

  import Imagex.Parameters.Shared

  @doc """
  The parsed parameters used by `Imagex.Transform.Focus`.
  """
  defstruct [:left, :top]

  @type t :: %__MODULE__{
          left: integer(),
          top: integer()
        }

  defcombinator(
    :dimensions,
    unwrap_and_tag(parsec(:int_size), :x)
    |> ignore(ascii_char([?x]))
    |> unwrap_and_tag(parsec(:int_size), :y)
  )

  defparsec(
    :internal_parse,
    tag(parsec(:dimensions), :crop_size)
    |> eos()
  )

  @doc """
  Parses a string into a `Imagex.Transform.Crop.Parameters` struct.

  Returns a `Imagex.Transform.Focus.Parameters` struct.

  ## Format

  ```
  <width>x<height>[@<left>x<top>]
  ```

  ## Units

  Type      | Format
  --------- | ------------
  `pixel`   | `<int>`

  ## Examples

      iex> Imagex.Transform.Focus.Parameters.parse("250x25")
      {:ok, %Imagex.Transform.Focus.Parameters{left: 250, top: 25}}
  """
  def parse(parameters) do
    case __MODULE__.internal_parse(parameters) do
      {:ok, [crop_size: [x: {:int, left}, y: {:int, top}]], _, _, _, _} ->
        {:ok, %__MODULE__{left: left, top: top}}

      {:error, _, _, _, _, _} ->
        {:error, :parameter_parse_error}
    end
  end
end
