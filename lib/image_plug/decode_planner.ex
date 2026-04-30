defmodule ImagePlug.DecodePlanner do
  @moduledoc false

  @type access_requirement() :: :sequential | :random | :neutral

  @spec open_options(ImagePlug.TransformChain.t()) :: keyword()
  def open_options(chain) when is_list(chain) do
    [access: access(chain), fail_on: :error]
  end

  @spec access(ImagePlug.TransformChain.t()) :: :sequential | :random
  def access(chain) when is_list(chain) do
    chain
    |> Enum.map(&access_requirement/1)
    |> fold_access()
  end

  defp access_requirement({module, params}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :metadata, 1) do
      params
      |> module.metadata()
      |> access_from_metadata()
    else
      :random
    end
  end

  defp access_requirement(_operation), do: :random

  defp access_from_metadata(%{} = metadata) do
    metadata
    |> Map.get(:access, :random)
    |> normalize_access()
  end

  defp access_from_metadata(_metadata), do: :random

  defp normalize_access(access) when access in [:sequential, :random, :neutral], do: access
  defp normalize_access(_access), do: :random

  defp fold_access([]), do: :random

  defp fold_access(requirements) do
    cond do
      Enum.any?(requirements, &(&1 == :random)) -> :random
      Enum.any?(requirements, &(&1 == :sequential)) -> :sequential
      true -> :random
    end
  end
end
