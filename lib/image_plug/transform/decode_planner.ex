defmodule ImagePlug.Transform.DecodePlanner do
  @moduledoc """
  Chooses image decode access from transform operation metadata.

  Decode planning interprets each operation's product-neutral metadata and
  reduces the chain to either sequential or random image access. It is
  intentionally conservative for valid metadata: empty chains, missing access
  metadata, and invalid access values all fall back to random access.
  """

  alias ImagePlug.Transform

  @type access_requirement() :: :sequential | :random | :neutral

  @spec open_options(ImagePlug.Transform.Chain.t()) :: keyword()
  def open_options(chain) when is_list(chain) do
    [access: access(chain), fail_on: :error]
  end

  @spec access(ImagePlug.Transform.Chain.t()) :: :sequential | :random
  def access([]), do: :random

  def access(chain) when is_list(chain) do
    chain
    |> Enum.map(&access_requirement/1)
    |> resolve_access()
  end

  defp access_requirement(operation) do
    operation
    |> Transform.metadata()
    |> access_from_metadata()
  end

  defp access_from_metadata(%{access: access}), do: normalize_access(access)
  defp access_from_metadata(_metadata), do: :random

  defp normalize_access(access) when access in [:sequential, :random, :neutral], do: access
  defp normalize_access(_access), do: :random

  defp resolve_access(requirements) do
    cond do
      Enum.any?(requirements, &(&1 == :random)) -> :random
      Enum.any?(requirements, &(&1 == :sequential)) -> :sequential
      true -> :random
    end
  end
end
