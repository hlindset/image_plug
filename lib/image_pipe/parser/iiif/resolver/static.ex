defmodule ImagePipe.Parser.IIIF.Resolver.Static do
  @moduledoc """
  Resolves an identifier from a static `%{identifier => Plan.Source.t()}` map.
  Opaque IDs, no source-structure leakage. Unknown id -> `{:error, :not_found}`.
  """

  @behaviour ImagePipe.Parser.IIIF.Resolver

  @impl true
  def resolve(identifier, opts) when is_binary(identifier) do
    map = Keyword.fetch!(opts, :map)

    case Map.fetch(map, identifier) do
      {:ok, %_{} = source} -> {:ok, source}
      :error -> {:error, :not_found}
    end
  end
end
