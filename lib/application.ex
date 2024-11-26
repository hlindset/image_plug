defmodule PlugImage.Application do
  use Application

  require Logger

  def start(_type, _args) do
    children = [
      {Bandit, plug: PlugImage.SimpleServer}
    ]

    opts = [strategy: :one_for_one, name: PlugImage.Supervisor]

    Logger.info("Starting application...")
    Supervisor.start_link(children, opts)
  end
end
