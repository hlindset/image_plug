defmodule ImagePlug.Output do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Format, ImagePlug.Plan],
    exports: [
      Policy,
      Encoder,
      Negotiation,
      Resolved
    ]
end
