defmodule ImagePlug.ParamParser.Twicpics.OutputParser do
  alias ImagePlug.Transform.Output.OutputParams

  @doc """
  Parses a string into a `ImagePlug.Transform.Output.OutputParams` struct.

  Returns a `ImagePlug.Transform.Output.OutputParams` struct.

  ## Examples

      iex> ImagePlug.ParamParser.Twicpics.OutputParser.parse("avif")
      {:ok, %ImagePlug.Transform.Output.OutputParams{format: :avif}}
  """
  def parse(parameters) do
    case parameters do
      "auto" -> {:ok, %OutputParams{format: :auto}}
      "avif" -> {:ok, %OutputParams{format: :avif}}
      "webp" -> {:ok, %OutputParams{format: :webp}}
      "jpeg" -> {:ok, %OutputParams{format: :jpeg}}
      "png" -> {:ok, %OutputParams{format: :png}}
      "blurhash" -> {:ok, %OutputParams{format: :blurhash}}
      _ -> {:error, :parameter_parse_error}
    end
  end
end
