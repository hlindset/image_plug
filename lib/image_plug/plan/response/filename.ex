defmodule ImagePlug.Plan.Response.Filename do
  @moduledoc false

  @enforce_keys [:stem]
  defstruct [:stem]

  @type t :: %__MODULE__{
          stem: String.t()
        }

  @spec new(String.t()) :: {:ok, t()} | {:error, term()}
  def new(stem) when is_binary(stem) do
    if valid_stem?(stem) do
      {:ok, %__MODULE__{stem: stem}}
    else
      {:error, {:invalid_response_filename, stem}}
    end
  end

  def new(stem), do: {:error, {:invalid_response_filename, stem}}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{stem: stem}), do: valid_stem?(stem)
  def valid?(_filename), do: false

  defp valid_stem?(stem) when is_binary(stem) do
    String.valid?(stem) and stem != "" and not String.contains?(stem, ["/", "\\"]) and
      not has_control_character?(stem)
  end

  defp valid_stem?(_stem), do: false

  defp has_control_character?(stem) do
    stem
    |> String.to_charlist()
    |> Enum.any?(&(&1 in 0..31 or &1 == 127))
  end
end
