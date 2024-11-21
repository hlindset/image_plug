defmodule Imagex.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ImagexWeb.Telemetry,
      Imagex.Repo,
      {DNSCluster, query: Application.get_env(:imagex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Imagex.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Imagex.Finch},
      # Start a worker by calling: Imagex.Worker.start_link(arg)
      # {Imagex.Worker, arg},
      # Start to serve requests, typically the last entry
      ImagexWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Imagex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ImagexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
