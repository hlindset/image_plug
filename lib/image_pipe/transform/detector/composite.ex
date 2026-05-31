defmodule ImagePipe.Transform.Detector.Composite do
  @moduledoc """
  A `ImagePipe.Transform.Detector` that fans a requested class set out across an
  ordered list of child detectors and merges their regions.

  Each requested class routes to the child(ren) whose `supported_classes/1` claim
  it (`:all` routes to every child); classes no child claims are dropped
  (best-effort). Identity and availability are class-aware: they reflect only the
  children a given request routes to, so e.g. an object-only request is unaffected
  by a face-model change. The bundled default composes the face (YuNet) and object
  (RT-DETR) adapters.
  """
  @behaviour ImagePipe.Transform.Detector

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Detector.ImageVision

  @default_children [ImageVision.Face, ImageVision.Objects]

  @type t :: %__MODULE__{children: [module()]}
  defstruct children: @default_children

  @spec new([module()]) :: t()
  def new(children) when is_list(children), do: %__MODULE__{children: children}

  @spec default() :: t()
  def default, do: %__MODULE__{children: @default_children}

  # --- Explicit-composite helpers and Detector behaviour ---
  #
  # supported_classes/1 is shared between the behaviour (takes opts keyword)
  # and the explicit helper (takes a %Composite{} struct). The struct clause is
  # listed first so it matches before the catch-all opts clause.

  @spec supported_classes(t()) :: [String.t()]
  def supported_classes(%__MODULE__{children: children}) do
    children |> Enum.flat_map(& &1.supported_classes([])) |> Enum.uniq()
  end

  @impl true
  def supported_classes(_opts), do: supported_classes(default())

  @impl true
  def detect(image, opts), do: detect(default(), image, opts)

  @impl true
  def available?(opts), do: available?(default(), opts)

  @impl true
  def identity(opts), do: identity(default(), opts)

  @impl true
  def warmup(opts) do
    Enum.reduce_while(default().children, :ok, fn child, _ ->
      case ImagePipe.Transform.Detector.warmup(child, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @spec detect(t(), term(), keyword()) :: {:ok, [map()]}
  def detect(%__MODULE__{} = composite, image, opts) do
    classes = Keyword.get(opts, :classes, :all)
    telemetry_opts = Keyword.get(opts, :telemetry_opts)

    regions =
      composite
      |> routed(classes)
      |> Enum.flat_map(fn {child, child_classes} ->
        run_child(child, child_classes, image, opts, telemetry_opts)
      end)

    {:ok, regions}
  end

  defp run_child(child, child_classes, image, opts, nil) do
    detect_child(child, child_classes, image, opts)
  end

  defp run_child(child, child_classes, image, opts, telemetry_opts) do
    start_meta = %{detector: child, model: child.identity(opts), classes: child_classes}

    Telemetry.span(telemetry_opts, [:transform, :detect, :model], start_meta, fn ->
      regions = detect_child(child, child_classes, image, opts)
      {regions, %{regions: length(regions)}}
    end)
  end

  defp detect_child(child, child_classes, image, opts) do
    case child.detect(image, Keyword.put(opts, :classes, child_classes)) do
      {:ok, regions} -> regions
      {:error, _} -> []
    end
  end

  @spec available?(t(), keyword()) :: boolean()
  def available?(%__MODULE__{} = composite, opts) do
    classes = Keyword.get(opts, :classes, :all)

    composite
    |> routed(classes)
    |> Enum.all?(fn {child, _} -> child.available?(opts) end)
  end

  @spec identity(t(), keyword()) :: {module(), [term()]}
  def identity(%__MODULE__{} = composite, opts) do
    classes = Keyword.get(opts, :classes, :all)
    ids = composite |> routed(classes) |> Enum.map(fn {child, _} -> child.identity(opts) end)
    {__MODULE__, ids}
  end

  # Returns [{child_module, child_classes}] for the children that the requested
  # class set routes to, preserving the fixed child order. `:all` -> every child
  # gets `:all`. A class list -> each child gets the intersection with its
  # supported set, and children with an empty intersection are dropped.
  defp routed(%__MODULE__{children: children}, :all) do
    Enum.map(children, &{&1, :all})
  end

  defp routed(%__MODULE__{children: children}, classes) when is_list(classes) do
    requested = MapSet.new(classes)

    children
    |> Enum.map(fn child ->
      child_classes = Enum.filter(child.supported_classes([]), &MapSet.member?(requested, &1))
      {child, child_classes}
    end)
    |> Enum.reject(fn {_child, child_classes} -> child_classes == [] end)
  end
end
