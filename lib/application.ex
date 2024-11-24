defmodule Imagex.Application do
  use Application

  require Logger

  def start(_type, _args) do
    children = [
      {Bandit, plug: Imagex.SimpleServer}
    ]

    opts = [strategy: :one_for_one, name: Imagex.Supervisor]

    Logger.info("Starting application...")
    Supervisor.start_link(children, opts)
  end
end
