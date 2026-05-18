defmodule ImagePlug.SourceTest.ValidAdapter do
  @moduledoc false

  @behaviour ImagePlug.Source

  @impl ImagePlug.Source
  def validate_options(opts), do: {:ok, opts}

  @impl ImagePlug.Source
  def resolve(source, opts, runtime_opts) do
    send(self(), {:source_resolve, source})
    send(self(), {:source_resolve_runtime_opts, runtime_opts})

    {:ok,
     %ImagePlug.Source.Resolved{
       adapter: Keyword.get(opts, :adapter, :path),
       source_kind: :path,
       identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
       cache: Keyword.get(opts, :cache, :normal),
       fetch: :fixture
     }}
  end

  @impl ImagePlug.Source
  def fetch(resolved, _opts, runtime_opts) do
    send(self(), {:source_fetch, resolved.fetch})
    send(self(), {:source_fetch_runtime_opts, runtime_opts})
    {:ok, %ImagePlug.Source.Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
  end
end
