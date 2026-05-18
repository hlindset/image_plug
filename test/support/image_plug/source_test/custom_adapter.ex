defmodule ImagePlug.SourceTest.CustomAdapter do
  @moduledoc false

  use Boundary, top_level?: true, deps: [ImagePlug.Source]

  alias ImagePlug.Source
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response

  @behaviour Source

  @impl Source
  def validate_options(opts) do
    send(self(), {:validate_options, opts})
    {:ok, Keyword.put(opts, :validated, true)}
  end

  @impl Source
  def resolve(source, opts, runtime_opts) do
    send(self(), {:resolve, source, opts, runtime_opts})

    {:ok,
     %Resolved{
       adapter: Keyword.fetch!(opts, :adapter),
       source_kind: :path,
       identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
       cache: Keyword.get(opts, :cache, :normal),
       fetch: {:source, source}
     }}
  end

  @impl Source
  def fetch(%Resolved{} = resolved, opts, runtime_opts) do
    send(self(), {:fetch, resolved, opts, runtime_opts})
    {:ok, %Response{stream: ["image", " bytes"]}}
  end
end
