defmodule ImagePipe.Plan.SourceInfo do
  @moduledoc """
  Product-neutral facts about a decoded source image, read from the lazy header
  open. Consumed by renderer modules. `width`/`height` are the STORED
  (pre-orientation) dimensions; renderers apply orientation as needed. `byte_size`
  is the lone non-header field, filled by the request layer from the source response
  / filesystem (nil when unavailable).
  """

  @enforce_keys [:format, :width, :height, :orientation]
  defstruct @enforce_keys ++ [byte_size: nil]

  @type t :: %__MODULE__{
          format: atom(),
          width: pos_integer(),
          height: pos_integer(),
          orientation: 1..8,
          byte_size: non_neg_integer() | nil
        }
end
