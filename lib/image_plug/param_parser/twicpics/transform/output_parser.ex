defmodule ImagePlug.ParamParser.Twicpics.Transform.OutputParser do
  alias ImagePlug.ParamParser.Twicpics.CoordinatesParser
  alias ImagePlug.ParamParser.Twicpics.Utils

  alias ImagePlug.Transform.Output.OutputParams

  @formats %{
    "auto" => :auto,
    "avif" => :avif,
    "webp" => :webp,
    "jpeg" => :jpeg,
    "png" => :png,
    "blurhash" => :blurhash
  }

  @doc """
  Parses a string into a `ImagePlug.Transform.Output.OutputParams` struct.

  Syntax:
  * `output=<format>`
  * `output=<preview type>`

  ## Examples
      iex> ImagePlug.ParamParser.Twicpics.Transform.OutputParser.parse("avif")
      {:ok, %ImagePlug.Transform.Output.OutputParams{format: :avif}}

      iex> ImagePlug.ParamParser.Twicpics.Transform.OutputParser.parse("blurhash")
      {:ok, %ImagePlug.Transform.Output.OutputParams{format: :blurhash}}
  """
  def parse(input, pos_offset \\ 0) do
    case Map.get(@formats, input) do
      format when is_atom(format) ->
        {:ok, %OutputParams{format: format}}

      _ ->
        Utils.unexpected_value_error(pos_offset, Map.keys(@formats), input)
        |> Utils.update_error_input(input)
    end
  end
end
