defmodule ImagePlug.ParamParser.Twicpics.FocusParser do
  import ImagePlug.ParamParser.Twicpics.Common

  alias ImagePlug.Transform.Focus.FocusParams

  @doc """
  Parses a string into a `ImagePlug.Transform.Focus.FocusParams` struct.

  Returns a `ImagePlug.Transform.Focus.FocusParams` struct.

  ## Format

  ```
  focus=<coordinates>
  focus=<anchor>
  ```

  Note: `auto` is not supported at the moment.

  ## Examples

      iex> ImagePlug.ParamParser.Twicpics.FocusParser.parse("250x25.5")
      {:ok, %ImagePlug.Transform.Focus.FocusParams{type: {:coordinate, {:int, 250}, {:float, 25.5}}}}

      iex> ImagePlug.ParamParser.Twicpics.FocusParser.parse("bottom-right")
      {:ok, %ImagePlug.Transform.Focus.FocusParams{type: {:coordinate, {:int, 250}, {:float, 25.5}}}}
  """
  def parse(input) do
    cond do
      Regex.match?(~r/^(.+)x(.+)$/, input) ->
        Regex.run(~r/^(.+)x(.+)$/, input, capture: :all_but_first)
        |> with_parsed_units(fn [left, top] ->
          {:ok, %FocusParams{type: {:coordinate, left, top}}}
        end)

      input == "center" ->
        {:ok, %FocusParams{type: {:anchor, {:center, :center}}}}

      input == "bottom" ->
        {:ok, %FocusParams{type: {:anchor, {:center, :bottom}}}}

      input == "bottom-left" ->
        {:ok, %FocusParams{type: {:anchor, {:left, :bottom}}}}

      input == "bottom-right" ->
        {:ok, %FocusParams{type: {:anchor, {:right, :bottom}}}}

      input == "left" ->
        {:ok, %FocusParams{type: {:anchor, {:left, :center}}}}

      input == "top" ->
        {:ok, %FocusParams{type: {:anchor, {:center, :top}}}}

      input == "top-left" ->
        {:ok, %FocusParams{type: {:anchor, {:left, :top}}}}

      input == "top-right" ->
        {:ok, %FocusParams{type: {:anchor, {:right, :top}}}}

      input == "right" ->
        {:ok, %FocusParams{type: {:anchor, {:right, :center}}}}

      true ->
        {:error, {:parameter_parse_error, input}}
    end
  end
end
