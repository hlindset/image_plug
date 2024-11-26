defmodule ImagePlug.ParamParser.Twicpics.CropParser do
  import NimbleParsec

  import ImagePlug.ParamParser.Twicpics.Shared

  alias ImagePlug.Transform.Crop.CropParams

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
  Parses a string into a `ImagePlug.Transform.Crop.CropParams` struct.

  Returns a `ImagePlug.Transform.Crop.CropParams` struct.

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

      iex> ImagePlug.ParamParser.Twicpics.CropParser.parse("250x25p")
      {:ok, %ImagePlug.Transform.Crop.CropParams{width: {:int, 250}, height: {:pct, 25.0}, crop_from: :focus}}

      iex> ImagePlug.ParamParser.Twicpics.CropParser.parse("20px25@10x50.1p")
      {:ok, %ImagePlug.Transform.Crop.CropParams{width: {:pct, 20.0}, height: {:int, 25}, crop_from: %{left: {:int, 10}, top: {:pct, 50.1}}}}
  """
  def parse(parameters) do
    case internal_parse(parameters) do
      {:ok, [crop_size: [x: width, y: height], coordinates: [x: left, y: top]], _, _, _, _} ->
        {:ok, %CropParams{width: width, height: height, crop_from: %{left: left, top: top}}}

      {:ok, [crop_size: [x: width, y: height]], _, _, _, _} ->
        {:ok, %CropParams{width: width, height: height, crop_from: :focus}}

      {:error, msg, _, _, _, _} ->
        {:error, {:parameter_parse_error, msg, parameters}}
    end
  end
end
