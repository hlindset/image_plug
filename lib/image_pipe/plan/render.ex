defmodule ImagePipe.Plan.Render do
  @moduledoc """
  Selects a non-image terminal renderer for a plan. `module` is the renderer module
  (implementing the `ImagePipe.Renderer` behaviour) that the host-configured parser
  emits — the core never resolves a tag or enumerates renderers. `params` carries
  renderer-specific options. The default `Plan.render` value `:image_encode` (no
  `Render` struct) means "encode an image".
  """

  @enforce_keys [:module]
  defstruct @enforce_keys ++ [params: %{}]

  @type t :: %__MODULE__{module: module(), params: map()}
end
