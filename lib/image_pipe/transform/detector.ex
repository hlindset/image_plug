defmodule ImagePipe.Transform.Detector do
  @moduledoc """
  Host-implementable content detection for content-aware gravity.

  Detectors translate image content into product-neutral regions. The default
  adapter wraps the optional `image_vision` dependency; hosts may inject their
  own. Return values cross a host boundary and are validated structurally by the
  caller (`ImagePipe.Transform.Operation.Crop`).
  """

  @typedoc """
  A detected region of interest.

  `box` is `{x, y, width, height}` in absolute top-left pixel coordinates of the
  input image (x grows right, y grows down). Host-written detectors must use this
  same convention so gravity targeting agrees across implementations.
  """
  @type region :: %{
          label: String.t(),
          score: float(),
          box: {number(), number(), number(), number()}
        }

  @doc "Detect regions of interest. `opts` carries `:classes`."
  @callback detect(image :: Vix.Vips.Image.t(), opts :: keyword()) ::
              {:ok, [region()]} | {:error, term()}

  @doc "Whether the detector can run now (e.g. the optional dependency is loaded)."
  @callback available?(opts :: keyword()) :: boolean()

  @doc "Stable identity for cache-key material."
  @callback identity(opts :: keyword()) :: {module(), term()}

  @doc "Optionally pre-load models so the first request avoids download cost."
  @callback warmup(opts :: keyword()) :: :ok | {:error, term()}
  @optional_callbacks warmup: 1
end
