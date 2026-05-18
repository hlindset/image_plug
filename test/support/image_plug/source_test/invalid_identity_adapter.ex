defmodule ImagePlug.SourceTest.InvalidIdentityAdapter do
  @moduledoc false

  use Boundary, top_level?: true, deps: [ImagePlug.Source]

  alias ImagePlug.Source
  alias ImagePlug.Source.Resolved

  @behaviour Source

  @impl Source
  def validate_options(opts), do: {:ok, opts}

  @impl Source
  def resolve(_source, _opts, _runtime_opts) do
    {:ok,
     %Resolved{
       adapter: :path,
       source_kind: :path,
       identity: [kind: :path, client: self()],
       cache: :skip,
       fetch: :bad_identity
     }}
  end

  @impl Source
  def fetch(_resolved, _opts, _runtime_opts) do
    raise "invalid identity must fail before fetch"
  end
end
