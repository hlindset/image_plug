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

  @doc """
  The class names this detector can produce, in the URL-facing spelling.

  Static metadata used to route a requested class set to detectors and to gate
  availability — it MUST NOT load a model and MUST be answerable even when the
  detector's optional dependency is absent (so a routing/availability decision
  can be made without the dep). `available?/1` may be `false` while this still
  returns the full vocabulary.
  """
  @callback supported_classes(opts :: keyword()) :: [String.t()]

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

  @doc """
  Invoke the optional `warmup/1` callback if the detector implements it, else `:ok`.

  Because `Detector` is host-implementable, a host detector may legitimately not
  implement `warmup/1`. The `function_exported?/3` presence check here is the
  sanctioned host-boundary exception to the no-duck-typing rule (the same pattern
  `ImagePipe.Cache.normalize_adapter_options/2` uses for its optional
  `validate_options/1` callback) — it is a capability check at a host boundary,
  not internal dispatch.
  """
  @spec warmup(module(), keyword()) :: :ok | {:error, term()}
  def warmup(module, opts) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :warmup, 1),
      do: module.warmup(opts),
      else: :ok
  end
end
