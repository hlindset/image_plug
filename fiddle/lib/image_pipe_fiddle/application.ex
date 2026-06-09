defmodule ImagePipeFiddle.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :persistent_term.put({__MODULE__, :imgproxy_opts}, build_imgproxy_opts())

    children = [
      ImagePipeFiddleWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:image_pipe_fiddle, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ImagePipeFiddle.PubSub},
      # Start a worker by calling: ImagePipeFiddle.Worker.start_link(arg)
      # {ImagePipeFiddle.Worker, arg},
      # Start to serve requests, typically the last entry
      ImagePipeFiddleWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ImagePipeFiddle.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ImagePipeFiddleWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp build_imgproxy_opts do
    imgproxy = Application.fetch_env!(:image_pipe_fiddle, :imgproxy)
    static_root = Application.app_dir(:image_pipe_fiddle, "priv/static")

    [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted}
      ],
      imgproxy: imgproxy,
      detector_required: true
    ]
    |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
    |> ImagePipe.Plug.init()
  end

  defp maybe_put_cache(opts, nil), do: opts
  defp maybe_put_cache(opts, cache), do: Keyword.put(opts, :cache, cache)
end
