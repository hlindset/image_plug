defmodule ImagePlug.Output do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Plan],
    exports: [
      Format,
      Policy,
      Encoder,
      Negotiation,
      Resolved
    ]
end
