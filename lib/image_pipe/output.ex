defmodule ImagePipe.Output do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Format, ImagePipe.Plan],
    exports: [
      Capabilities,
      Policy,
      Encoder,
      Negotiation,
      Resolved
    ]
end
