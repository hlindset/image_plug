defmodule ImagePipe.Plan.RenderContext do
  @moduledoc """
  Inputs a renderer formats over, assembled by the request layer. Phase 1 carries
  only header facts (`info`). Future depths (pixels, detector, raw bytes) add fields
  populated by their satisfier stages; a future `image` field would be a plain
  `Vix.Vips.Image.t()` (never a `Transform.State`), so renderers never depend on
  `Transform.*`.
  """

  @enforce_keys [:info]
  defstruct @enforce_keys

  @type t :: %__MODULE__{info: ImagePipe.Plan.SourceInfo.t()}
end
