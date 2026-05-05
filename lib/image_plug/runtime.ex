defmodule ImagePlug.Runtime do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePlug.Plan,
      ImagePlug.Cache,
      ImagePlug.Output,
      ImagePlug.Transform
    ],
    exports: [
      RequestRunner,
      Origin,
      ResponseSender,
      SourceIdentity,
      Options
    ]
end
