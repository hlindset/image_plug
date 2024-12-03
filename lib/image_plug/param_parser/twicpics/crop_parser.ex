defmodule ImagePlug.ParamParser.Twicpics.CropParser do
  import ImagePlug.ParamParser.Twicpics.Common

  alias ImagePlug.Transform.Crop.CropParams

  @doc """
  Parses a string into a `ImagePlug.Transform.Crop.CropParams` struct.

  Returns a `ImagePlug.Transform.Crop.CropParams` struct.

  ## Format

  ```
  <crop_size>[@<coordinates>]
  ```

  ## Examples

      iex> ImagePlug.ParamParser.Twicpics.CropParser.parse("250x25p")
      {:ok, %ImagePlug.Transform.Crop.CropParams{width: {:int, 250}, height: {:pct, {:int, 25}}, crop_from: :focus}}

      iex> ImagePlug.ParamParser.Twicpics.CropParser.parse("20px25@10x50.1p")
      {:ok, %ImagePlug.Transform.Crop.CropParams{width: {:pct, {:int, 20}}, height: {:int, 25}, crop_from: %{left: {:int, 10}, top: {:pct, {:float, 50.1}}}}}
  """
  def parse(input) do
    cond do
      Regex.match?(~r/^(.+)x(.+)@(.+)x(.+)$/, input) ->
        Regex.run(~r/^(.+)x(.+)@(.+)x(.+)$/, input, capture: :all_but_first)
        |> with_parsed_units(fn [width, height, left, top] ->
          {:ok,
           %CropParams{
             width: width,
             height: height,
             crop_from: %{left: left, top: top}
           }}
        end)

      Regex.match?(~r/^(.+)x(.+)$/, input) ->
        Regex.run(~r/^(.+)x(.+)$/, input, capture: :all_but_first)
        |> with_parsed_units(fn [width, height] ->
          {:ok,
           %CropParams{
             width: width,
             height: height,
             crop_from: :focus
           }}
        end)

      true ->
        {:error, {:parameter_parse_error, input}}
    end
  end
end
