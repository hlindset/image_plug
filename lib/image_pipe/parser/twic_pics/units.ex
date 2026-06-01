defmodule ImagePipe.Parser.TwicPics.Units do
  @moduledoc false

  import Kernel, except: [length: 1]

  @type length :: {:px, pos_integer()} | {:percent, number()} | {:scale, number()}

  @spec length(String.t()) :: {:ok, length()} | {:error, term()}
  def length("-"), do: {:error, {:invalid_length, "-"}}

  def length(value) when is_binary(value) do
    cond do
      String.ends_with?(value, "px") -> pixels(String.trim_trailing(value, "px"))
      String.ends_with?(value, "p") -> percent(String.trim_trailing(value, "p"))
      String.ends_with?(value, "s") -> scale(String.trim_trailing(value, "s"))
      true -> pixels(value)
    end
  end

  defp pixels(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, {:px, n}}
      _ -> {:error, {:invalid_length, value}}
    end
  end

  defp percent(value) do
    with {:ok, n} <- number(value), true <- n > 0 do
      {:ok, {:percent, n}}
    else
      _ -> {:error, {:invalid_length, value}}
    end
  end

  defp scale(value) do
    with {:ok, n} <- number(value), true <- n > 0 do
      {:ok, {:scale, n}}
    else
      _ -> {:error, {:invalid_length, value}}
    end
  end

  @doc false
  @spec number(String.t()) :: {:ok, number()} | :error
  def number(value) do
    case Integer.parse(value) do
      {n, ""} ->
        {:ok, n}

      _ ->
        case Float.parse(value) do
          {n, ""} -> {:ok, n}
          _ -> :error
        end
    end
  end
end
