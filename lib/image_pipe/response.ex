defmodule ImagePipe.Response do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Error,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Telemetry
    ],
    exports: [
      PreparedStream,
      Sender
    ]
end
