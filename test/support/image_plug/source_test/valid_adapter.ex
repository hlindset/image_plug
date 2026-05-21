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
       fetch: {:fixture, self()}
     }}
  end

  @impl ImagePlug.Source
  def fetch(%ImagePlug.Source.Resolved{fetch: {:fixture, receiver}}, _opts, runtime_opts) do
    send(receiver, {:source_fetch, :fixture})
    send(receiver, {:source_fetch_runtime_opts, runtime_opts})
    {:ok, %ImagePlug.Source.Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
  end

  def fetch(resolved, _opts, runtime_opts) do
    target = message_target()

    send(target, {:source_fetch, resolved.fetch})
    send(target, {:source_fetch_runtime_opts, runtime_opts})
    {:ok, %ImagePlug.Source.Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
  end

  defp message_target do
    case Process.get(:"$callers") do
      [pid | _rest] when is_pid(pid) -> pid
      _callers -> self()
    end
  end
end
