defmodule ImagePlug.SourceTest.PlugCustomAdapter do
  @moduledoc false

  use Boundary, top_level?: true, deps: [ImagePlug.Source]

  alias ImagePlug.Source
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response

  @behaviour Source

  @impl true
  def validate_options(opts), do: {:ok, opts}

  @impl true
  def resolve(source, opts, _runtime_opts) do
    send(self(), {:source_order, :resolve})
    send(self(), {:custom_resolve, source})

    {:ok,
     %Resolved{
       adapter: Keyword.fetch!(opts, :adapter),
       source_kind: :object,
       identity: [
         kind: :object,
         adapter: Keyword.fetch!(opts, :adapter),
         scope: "custom",
         key: "cat.jpg"
       ],
       cache: Keyword.get(opts, :cache, :normal),
       fetch: :cat
     }}
  end

  @impl true
  def fetch(%Resolved{} = resolved, _opts, _runtime_opts) do
    send(self(), {:source_order, :fetch})
    send(self(), {:custom_fetch, resolved.fetch})
    {:ok, %Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
  end
end
