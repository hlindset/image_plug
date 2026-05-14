defmodule ImagePlug.Parser.Imgproxy.Presets do
  @moduledoc false

  @enforce_keys [:definitions]
  defstruct @enforce_keys

  @type group :: [String.t()]
  @type t :: %__MODULE__{definitions: %{String.t() => [group()]}}

  @spec empty() :: t()
  def empty, do: %__MODULE__{definitions: %{}}

  @spec validate_config(term()) :: {:ok, t()} | {:error, String.t()}
  def validate_config(%_{}), do: {:error, "presets must be a map"}

  def validate_config(presets) when is_map(presets) do
    presets
    |> Enum.reduce_while({:ok, %{}}, fn {name, value}, {:ok, definitions} ->
      with :ok <- validate_name(name),
           :ok <- validate_value(name, value),
           {:ok, groups} <- tokenize(value) do
        {:cont, {:ok, Map.put(definitions, name, groups)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, definitions} -> {:ok, %__MODULE__{definitions: definitions}}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_config(_presets), do: {:error, "presets must be a map"}

  @spec fetch(t(), String.t()) :: {:ok, [group()]} | :error
  def fetch(%__MODULE__{definitions: definitions}, name) when is_binary(name),
    do: Map.fetch(definitions, name)

  defp validate_name(name) when is_binary(name) and name != "", do: :ok
  defp validate_name(_name), do: {:error, "preset names must be non-empty strings"}

  defp validate_value(_name, value) when is_binary(value) and value != "", do: :ok

  defp validate_value(name, _value),
    do: {:error, "preset #{inspect(name)} must be a non-empty string"}

  defp tokenize(value) do
    value
    |> String.split("/", trim: false)
    |> Enum.reduce_while({:ok, [[]]}, &tokenize_segment/2)
    |> case do
      {:ok, groups} -> {:ok, groups |> Enum.reverse() |> Enum.map(&Enum.reverse/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tokenize_segment("-", {:ok, groups}), do: {:cont, {:ok, [[] | groups]}}

  defp tokenize_segment("", {:ok, _groups}),
    do: {:halt, {:error, "preset values must not contain empty option segments"}}

  defp tokenize_segment(segment, {:ok, [group | groups]}) do
    case preset_reference_args(segment) do
      {:ok, []} ->
        {:halt, {:error, "preset references must include at least one non-empty preset name"}}

      {:ok, names} ->
        case Enum.any?(names, &(&1 == "")) do
          true -> {:halt, {:error, "preset references must include non-empty preset names"}}
          false -> {:cont, {:ok, [[segment | group] | groups]}}
        end

      :not_preset ->
        {:cont, {:ok, [[segment | group] | groups]}}
    end
  end

  defp preset_reference_args(segment) do
    case String.split(segment, ":") do
      [name | args] when name in ["preset", "pr"] -> {:ok, args}
      _parts -> :not_preset
    end
  end
end
