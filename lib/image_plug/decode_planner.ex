defmodule ImagePlug.DecodePlanner do
  @moduledoc false

  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.Transform

  @type access_requirement() :: :sequential | :random | :neutral

  @spec open_options(Plan.t() | ImagePlug.TransformChain.t()) :: keyword()
  def open_options(%Plan{pipelines: [%Pipeline{operations: operations} | _rest]}) do
    open_options(operations)
  end

  def open_options(chain) when is_list(chain) do
    [access: access(chain), fail_on: :error]
  end

  @spec access(ImagePlug.TransformChain.t()) :: :sequential | :random
  def access(chain) when is_list(chain) do
    chain
    |> Enum.map(&access_requirement/1)
    |> resolve_access()
  end

  defp access_requirement(operation) do
    operation
    |> safe_metadata()
    |> access_from_metadata()
  end

  defp safe_metadata(operation) do
    Transform.metadata(operation)
  rescue
    _exception -> %{access: :random}
  catch
    _kind, _reason -> %{access: :random}
  end

  defp access_from_metadata(%{access: access}), do: normalize_access(access)
  defp access_from_metadata(_metadata), do: :random

  defp normalize_access(access) when access in [:sequential, :random, :neutral], do: access
  defp normalize_access(_access), do: :random

  defp resolve_access([]), do: :random

  defp resolve_access(requirements) do
    cond do
      Enum.any?(requirements, &(&1 == :random)) -> :random
      Enum.any?(requirements, &(&1 == :sequential)) -> :sequential
      true -> :random
    end
  end
end
