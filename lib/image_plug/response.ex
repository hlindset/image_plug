defmodule ImagePlug.Response do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePlug.Cache,
      ImagePlug.Output,
      ImagePlug.Plan,
      ImagePlug.Telemetry
    ],
    exports: [
      PreparedStream,
      Sender
    ]
end
