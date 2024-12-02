defmodule ImagePlug.ParamParser.Twicpics.ContainParser do
  import ImagePlug.ParamParser.Twicpics.Common

  alias ImagePlug.Transform.Contain.ContainParams

  @doc """
  Parses a string into a `ImagePlug.Transform.Contain.ContainParams` struct.

  Returns a `ImagePlug.Transform.Contain.ContainParams` struct.

  ## Format

  ```
  <width>x<height>
  ```

  ## Units

  Type      | Format
  --------- | ------------
  `pixel`   | `<int>`

  ## Examples

      iex> ImagePlug.ParamParser.Twicpics.ContainParser.parse("250x25.5")
      {:ok, %ImagePlug.Transform.Contain.ContainParams{width: {:int, 250}, height: {:float, 25.5}}}
  """
  def parse(input) do
    cond do
      Regex.match?(~r/^(.+)x(.+)$/, input) ->
        Regex.run(~r/^(.+)x(.+)$/, input, capture: :all_but_first)
        |> with_parsed_units(fn [width, height] ->
          {:ok, %ContainParams{width: width, height: height}}
        end)

      true ->
        {:error, {:parameter_parse_error, input}}
    end
  end
end
