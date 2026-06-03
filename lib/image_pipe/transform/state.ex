defmodule ImagePipe.Transform.State do
  @moduledoc """
  Execution state carried through a transform chain.

  State holds the current image and debug flag used by product-neutral
  operations. Operations return an updated state instead of mutating images in
  place.

  Injected runtime configuration also rides on the state so operations can reach
  host-provided collaborators without naming concrete request modules:

  - `detector`: host-configured content detector, either a bare `module` or a
    `{module, opts}` pair, or `nil` when no detector is configured.
  - `detector_required`: whether detect-gravity must use the detector instead of
    silently falling back to attention smartcrop.
  - `telemetry_opts`: telemetry metadata threaded through stage spans.
  - `source_dimensions`: the *exact* original (full-resolution) `{w, h}` the
    residual resize must size against, set only when shrink-on-load has reduced the
    decoded image; `nil` otherwise. It is exact (not reconstructed from the shrunk
    dims), so the residual resize lands on the same target as a full-resolution
    decode. It stays in the storage frame — EXIF/user orientation is carried as a
    pending rotation on `pending_orientation` and flushed after the resize, so no
    pre-resize op swaps these dimensions. Shrink-on-load is declined when a
    quarter-turn rotate precedes the resize (see `ImagePipe.Transform.DecodePlanner`);
    a preceding crop no longer declines it (#151). The residual resize clears it to
    `nil`. A crop reached before the resize also clears it (the cropped live image is
    then the frame the resize sizes against), alongside `decode_shrink`.
  - `decode_shrink`: the *realized* per-axis shrink factor `%{w: float, h: float}`
    (each `>= 1.0`, original ÷ decoded) actually applied by shrink-on-load, or `nil`
    when the decode was full-resolution. A crop preceding the resize rescales its
    absolute pixel dims and pixel/absolute gravity offsets by this factor so the
    crop selects the same source region on the shrunk image that it would at full
    resolution; relative (ratio/percent/focus-point) coordinates are untouched.
    For JPEG block shrink and WebP scale-on-load the factor is uniform across axes.
  """

  defstruct image: nil,
            debug: false,
            detector: nil,
            detector_required: false,
            telemetry_opts: [],
            source_dimensions: nil,
            decode_shrink: nil,
            pending_orientation: nil,
            materialized?: false

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t() | nil,
          debug: boolean(),
          detector: module() | {module(), keyword()} | nil,
          detector_required: boolean(),
          telemetry_opts: keyword(),
          source_dimensions: {pos_integer(), pos_integer()} | nil,
          decode_shrink: %{w: float(), h: float()} | nil,
          pending_orientation: ImagePipe.Transform.PendingOrientation.t() | nil,
          materialized?: boolean()
        }

  def set_image(%__MODULE__{} = state, %Vix.Vips.Image{} = image) do
    %__MODULE__{state | image: image}
  end

  @doc """
  Dimensions the residual resize must size against.

  When shrink-on-load reduced the decoded image, this returns the exact stored
  original extent (`source_dimensions`), so the residual resize computes the same
  target a full-resolution decode would. With no shrink it returns the live image
  dimensions — which also makes a crop-before-resize correct, since the cropped
  image's own dimensions are what the following resize should size against.
  """
  def effective_source_dims(%__MODULE__{source_dimensions: {w, h}}), do: {w, h}

  def effective_source_dims(%__MODULE__{image: image}),
    do: {Image.width(image), Image.height(image)}
end
