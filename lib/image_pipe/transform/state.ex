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
  - `decode_prescale`: the uniform factor libvips already applied at decode via
    shrink-on-load, expressed as `loaded_dim / original_dim` (≤ 1.0; `1.0` means
    no shrink). Geometry that must reason about the *original* image extent reads
    it through `effective_source_dims/1`, which divides the current image dims by
    this factor. Because it is derived from the live image, it tracks crops and
    rotations automatically; the residual resize resets it to `1.0` once it has
    finished the downscale.
  """

  defstruct image: nil,
            debug: false,
            detector: nil,
            detector_required: false,
            telemetry_opts: [],
            decode_prescale: 1.0

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t() | nil,
          debug: boolean(),
          detector: module() | {module(), keyword()} | nil,
          detector_required: boolean(),
          telemetry_opts: keyword(),
          decode_prescale: number()
        }

  def set_image(%__MODULE__{} = state, %Vix.Vips.Image{} = image) do
    %__MODULE__{state | image: image}
  end

  @doc """
  Dimensions the current image would have at full (un-shrunk) resolution.

  When shrink-on-load has reduced the decoded image, this divides the live image
  dimensions by `decode_prescale` to recover the original-resolution extent the
  geometry math expects. With no shrink (`decode_prescale == 1.0`) it returns the
  image dimensions unchanged. Deriving from the live image means crops and
  rotations applied before the residual resize are reflected without any
  per-operation bookkeeping.
  """
  def effective_source_dims(%__MODULE__{image: image, decode_prescale: prescale}) do
    {logical_dim(Image.width(image), prescale), logical_dim(Image.height(image), prescale)}
  end

  defp logical_dim(dim, prescale), do: max(1, round(dim / prescale))
end
