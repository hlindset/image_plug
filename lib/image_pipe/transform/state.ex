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
  """

  defstruct image: nil,
            debug: false,
            detector: nil,
            detector_required: false,
            telemetry_opts: []

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t() | nil,
          debug: boolean(),
          detector: module() | {module(), keyword()} | nil,
          detector_required: boolean(),
          telemetry_opts: keyword()
        }

  def set_image(%__MODULE__{} = state, %Vix.Vips.Image{} = image) do
    %__MODULE__{state | image: image}
  end
end
