defmodule ImagePlug.ParamParser.Twicpics.FocusParser do
  import ImagePlug.ParamParser.Twicpics.Shared

  alias ImagePlug.Transform.Focus.FocusParams

  @doc """
  Parses a string into a `ImagePlug.Transform.Focus.FocusParams` struct.

  Returns a `ImagePlug.Transform.Focus.FocusParams` struct.

  ## Format

  ```
  <width>x<height>[@<left>x<top>]
  ```

  ## Units

  Type      | Format
  --------- | ------------
  `pixel`   | `<int>`

  ## Examples

      iex> ImagePlug.ParamParser.Twicpics.FocusParser.parse("250x25.5")
      {:ok, %ImagePlug.Transform.Focus.FocusParams{left: {:int, 250}, top: {:float, 25.5}}}
  """
  def parse(input) do
    cond do
      Regex.match?(~r/^(.+)x(.+)$/, input) ->
        Regex.run(~r/^(.+)x(.+)$/, input, capture: :all_but_first)
        |> with_parsed_units(fn [left, top] ->
          {:ok, %FocusParams{left: left, top: top}}
        end)

      true ->
        {:error, {:parameter_parse_error, input}}
    end
  end
end
