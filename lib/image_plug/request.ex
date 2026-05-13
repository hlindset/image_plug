defmodule ImagePlug.Request do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePlug.Plan,
      ImagePlug.Cache,
      ImagePlug.Origin,
      ImagePlug.Output,
      ImagePlug.Response,
      ImagePlug.Transform
    ],
    exports: [
      Options,
      Runner
    ]
end
