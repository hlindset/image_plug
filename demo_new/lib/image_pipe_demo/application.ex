defmodule ImagePipeDemo.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Dev/test harness: surface ImagePipe's telemetry through its built-in,
    # stdlib-Logger handler. Opt-in and idempotent; production hosts normally
    # attach their own handlers (metrics/OpenTelemetry/APM) instead. Flip
    # `debug: true` to also dump raw measurements/metadata (e.g. transform
    # operation params).
    ImagePipe.Telemetry.attach_default_logger(level: :info, events: :all)

    children = [
      ImagePipeDemoWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:image_pipe_demo, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ImagePipeDemo.PubSub},
      # Start a worker by calling: ImagePipeDemo.Worker.start_link(arg)
      # {ImagePipeDemo.Worker, arg},
      # Start to serve requests, typically the last entry
      ImagePipeDemoWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ImagePipeDemo.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ImagePipeDemoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
