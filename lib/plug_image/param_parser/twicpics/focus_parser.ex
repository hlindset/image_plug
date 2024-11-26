defmodule PlugImage.ParamParser.Twicpics.FocusParser do
  import NimbleParsec

  import PlugImage.ParamParser.Twicpics.Shared

  alias PlugImage.Transform.Focus.FocusParams

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
  Parses a string into a `PlugImage.Transform.Focus.FocusParams` struct.

  Returns a `PlugImage.Transform.Focus.FocusParams` struct.

  ## Format

  ```
  <width>x<height>[@<left>x<top>]
  ```

  ## Units

  Type      | Format
  --------- | ------------
  `pixel`   | `<int>`

  ## Examples

      iex> PlugImage.ParamParser.Twicpics.FocusParser.parse("250x25")
      {:ok, %PlugImage.Transform.Focus.FocusParams{left: 250, top: 25}}
  """
  def parse(parameters) do
    case internal_parse(parameters) do
      {:ok, [crop_size: [x: {:int, left}, y: {:int, top}]], _, _, _, _} ->
        {:ok, %FocusParams{left: left, top: top}}

      {:error, _, _, _, _, _} ->
        {:error, :parameter_parse_error}
    end
  end
end