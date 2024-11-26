defmodule PlugImage.ParamParser.Twicpics.OutputParser do
  alias PlugImage.Transform.Output.OutputParams

  @doc """
  Parses a string into a `PlugImage.Transform.Output.OutputParams` struct.

  Returns a `PlugImage.Transform.Output.OutputParams` struct.

  ## Examples

      iex> PlugImage.ParamParser.Twicpics.OutputParser.parse("avif")
      {:ok, %PlugImage.Transform.Output.OutputParams{format: :avif}}
  """
  def parse(parameters) do
    case parameters do
      "auto" -> {:ok, %OutputParams{format: :auto}}
      "avif" -> {:ok, %OutputParams{format: :avif}}
      "webp" -> {:ok, %OutputParams{format: :webp}}
      "jpeg" -> {:ok, %OutputParams{format: :jpeg}}
      "png" -> {:ok, %OutputParams{format: :png}}
      _ -> {:error, :parameter_parse_error}
    end
  end
end
