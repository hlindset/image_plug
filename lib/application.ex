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

  alias ImagePipe.Output.Capabilities

  def start(_type, _args) do
    Capabilities.probe()

    children = [
      ImagePipe.Request.SourceSessionSupervisor
    ]

    opts = [strategy: :one_for_one, name: ImagePipe.Supervisor]

    Logger.info("Starting application...")
    Supervisor.start_link(children, opts)
  end
end
