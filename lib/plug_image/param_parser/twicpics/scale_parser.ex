defmodule ImagePlug.ParamParser.Twicpics.ScaleParser do
  import ImagePlug.ParamParser.Twicpics.Shared

  alias ImagePlug.Transform.Scale.ScaleParams

  @doc """
  Parses a string into a `ImagePlug.Transform.Scale.ScaleParams` struct.

  Returns a `ImagePlug.Transform.Scale.ScaleParams` struct.

  ## Format

  ```
  <width>[x<height>]
  ```

  ## Units

  Type      | Format
  --------- | ------------
  `pixel`   | `<int>`
  `percent` | `<float>p`
  `auto`    | `-`

  Only one of the dimensions can be set to `auto`.

  ## Examples

      iex> ImagePlug.ParamParser.Twicpics.ScaleParser.parse("250x25p")
      {:ok, %ImagePlug.Transform.Scale.ScaleParams{width: {:int, 250}, height: {:pct, {:int, 25}}}}

      iex> ImagePlug.ParamParser.Twicpics.ScaleParser.parse("-x25p")
      {:ok, %ImagePlug.Transform.Scale.ScaleParams{width: :auto, height: {:pct, {:int, 25}}}}

      iex> ImagePlug.ParamParser.Twicpics.ScaleParser.parse("50.5px-")
      {:ok, %ImagePlug.Transform.Scale.ScaleParams{width: {:pct, {:float, 50.5}}, height: :auto}}

      iex> ImagePlug.ParamParser.Twicpics.ScaleParser.parse("50.5")
      {:ok, %ImagePlug.Transform.Scale.ScaleParams{width: {:float, 50.5}, height: :auto}}

      iex> ImagePlug.ParamParser.Twicpics.ScaleParser.parse("50p")
      {:ok, %ImagePlug.Transform.Scale.ScaleParams{width: {:pct, {:int, 50}}, height: :auto}}
  """
  def parse(input) do
    cond do
      Regex.match?(~r/^(.+)x-$/, input) ->
        Regex.run(~r/^(.+)x-$/, input, capture: :all_but_first)
        |> with_parsed_units(fn [width] ->
          {:ok, %ScaleParams{width: width, height: :auto}}
        end)

      Regex.match?(~r/^-x(.+)$/, input) ->
        Regex.run(~r/^-x(.+)$/, input, capture: :all_but_first)
        |> with_parsed_units(fn [height] ->
          {:ok, %ScaleParams{width: :auto, height: height}}
        end)

      Regex.match?(~r/^(.+)x(.+)$/, input) ->
        Regex.run(~r/^(.+)x(.+)$/, input, capture: :all_but_first)
        |> with_parsed_units(fn [width, height] ->
          {:ok, %ScaleParams{width: width, height: height}}
        end)

      Regex.match?(~r/^(.+)$/, input) ->
        Regex.run(~r/^(.+)$/, input, capture: :all_but_first)
        |> with_parsed_units(fn [width] ->
          {:ok, %ScaleParams{width: width, height: :auto}}
        end)

      true ->
        {:error, {:parameter_parse_error, input}}
    end
  end
end
