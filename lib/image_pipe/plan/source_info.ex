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

  @doc """
  Display (post-EXIF-orientation) dimensions. EXIF orientations 5–8 are
  quarter-turns, so the stored width/height are swapped; all others (and the
  no-rotation case) keep stored order. Pure derivation over this struct's fields.
  """
  @spec display_dimensions(t()) :: {pos_integer(), pos_integer()}
  def display_dimensions(%__MODULE__{width: w, height: h, orientation: o})
      when o in [5, 6, 7, 8],
      do: {h, w}

  def display_dimensions(%__MODULE__{width: w, height: h}), do: {w, h}
end
