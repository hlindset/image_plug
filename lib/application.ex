defmodule ImagePlug.Application do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: []

  use Application

  require Logger

  def start(_type, _args) do
    children = []

    opts = [strategy: :one_for_one, name: ImagePlug.Supervisor]

    Logger.info("Starting application...")
    Supervisor.start_link(children, opts)
  end
end
