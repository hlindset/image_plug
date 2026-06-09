defmodule ImagePipe.Plan.Operation.Trim do
  @moduledoc """
  Semantic uniform-border trim operation.

  Detects and removes a uniform-color border. `background: :auto` auto-detects the
  background from the image's top-left pixel (imgproxy "smart"); a `Color` uses an
  explicit background. `equal_hor`/`equal_ver` symmetrize opposite margins to the
  smaller inset. See `docs/imgproxy_support_matrix.md` (pipeline stage 2).
  """

  alias ImagePipe.Plan.Color

  @enforce_keys [:threshold, :background, :equal_hor, :equal_ver]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          threshold: float(),
          background: :auto | Color.t(),
          equal_hor: boolean(),
          equal_ver: boolean()
        }
end
