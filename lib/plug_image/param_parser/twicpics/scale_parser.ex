defmodule PlugImage.ParamParser.Twicpics.ScaleParser do
  import NimbleParsec

  import PlugImage.ParamParser.Twicpics.Shared

  alias PlugImage.Transform.Scale.ScaleParams

  auto_size =
    ignore(ascii_char([?*]))
    |> tag(:auto)
    |> replace(:auto)

  maybe_auto_size =
    choice([
      parsec(:int_or_pct_size),
      auto_size
    ])

  auto_width =
    unwrap_and_tag(maybe_auto_size, :width)
    |> ignore(ascii_char([?x]))
    |> unwrap_and_tag(parsec(:int_or_pct_size), :height)

  auto_height =
    unwrap_and_tag(parsec(:int_or_pct_size), :width)
    |> ignore(ascii_char([?x]))
    |> unwrap_and_tag(maybe_auto_size, :height)

  simple = unwrap_and_tag(parsec(:int_or_pct_size), :width)

  defparsecp(
    :internal_parse,
    choice([auto_width, auto_height, simple])
    |> eos()
  )

  @doc """
  Parses a string into a `PlugImage.Transform.Scale.ScaleParams` struct.

  Returns a `PlugImage.Transform.Scale.ScaleParams` struct.

  ## Format

  ```
  <width>[x<height>]
  ```

  ## Units

  Type      | Format
  --------- | ------------
  `pixel`   | `<int>`
  `percent` | `<float>p`
  `auto`    | `*`

  Only one of the dimensions can be set to `auto`.

  ## Examples

      iex> PlugImage.ParamParser.Twicpics.ScaleParser.parse("250x25p")
      {:ok, %PlugImage.Transform.Scale.ScaleParams{width: {:int, 250}, height: {:pct, 25.0}}}

      iex> PlugImage.ParamParser.Twicpics.ScaleParser.parse("*x25p")
      {:ok, %PlugImage.Transform.Scale.ScaleParams{width: :auto, height: {:pct, 25.0}}}

      iex> PlugImage.ParamParser.Twicpics.ScaleParser.parse("50px*")
      {:ok, %PlugImage.Transform.Scale.ScaleParams{width: {:pct, 50.0}, height: :auto}}

      iex> PlugImage.ParamParser.Twicpics.ScaleParser.parse("50")
      {:ok, %PlugImage.Transform.Scale.ScaleParams{width: {:int, 50}, height: :auto}}

      iex> PlugImage.ParamParser.Twicpics.ScaleParser.parse("50p")
      {:ok, %PlugImage.Transform.Scale.ScaleParams{width: {:pct, 50.0}, height: :auto}}
  """
  def parse(parameters) do
    case internal_parse(parameters) do
      {:ok, [width: width], _, _, _, _} ->
        {:ok, %ScaleParams{width: width, height: :auto}}

      {:ok, [width: width, height: height], _, _, _, _} ->
        {:ok, %ScaleParams{width: width, height: height}}

      {:error, msg, _, _, _, _} ->
        {:error, {:parameter_parse_error, msg, parameters}}
    end
  end
end
