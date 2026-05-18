defmodule ImagePlug.Request do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePlug.Plan,
      ImagePlug.Cache,
      ImagePlug.Source,
      ImagePlug.Output,
      ImagePlug.Response,
      ImagePlug.Telemetry,
      ImagePlug.Transform
    ],
    exports: [
      Options,
      Runner
    ]
end
