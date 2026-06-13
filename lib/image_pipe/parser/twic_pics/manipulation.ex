defmodule ImagePipe.Parser.TwicPics.Manipulation do
  @moduledoc false

  @spec parse(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def parse("v1/" <> rest), do: segments(rest)
  def parse("v1"), do: {:ok, []}
  def parse(other), do: {:error, {:unsupported_manipulation_version, other}}

  defp segments(rest) do
    rest
    |> String.split("/", trim: true)
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, acc} ->
      case String.split(segment, "=", parts: 2) do
        [name, args] -> {:cont, {:ok, [{name, args} | acc]}}
        [name] -> {:halt, {:error, {:invalid_segment, name}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end
end
