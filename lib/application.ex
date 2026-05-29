defmodule ImagePipe.Application do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Output,
      ImagePipe.Request
    ]

  use Application

  require Logger

  def start(_type, _args) do
    ImagePipe.Output.Capabilities.probe()

    children = [
      ImagePipe.Request.SourceSessionSupervisor
    ]

    opts = [strategy: :one_for_one, name: ImagePipe.Supervisor]

    Logger.info("Starting application...")
    Supervisor.start_link(children, opts)
  end
end
