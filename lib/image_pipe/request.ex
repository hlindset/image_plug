defmodule ImagePipe.Request do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Cache,
      ImagePipe.Source,
      ImagePipe.Output,
      ImagePipe.Response,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: [
      Options,
      Runner,
      SourceSessionSupervisor
    ]
end
