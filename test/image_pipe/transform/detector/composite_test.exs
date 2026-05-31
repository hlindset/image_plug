defmodule ImagePipe.Transform.Detector.CompositeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Detector.Composite

  # Fake children: each owns a vocabulary and returns one canned region per
  # routed class (label = class). Real @behaviour producers, so this is not an
  # impossible-internal-misuse test.
  defmodule FaceChild do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_), do: ["face"]
    @impl true
    def available?(opts), do: Keyword.get(opts, :face_available?, true)
    @impl true
    def identity(_), do: {__MODULE__, :face_v1}
    @impl true
    def detect(_image, opts), do: {:ok, regions_for(opts)}
    defp regions_for(opts) do
      requested(opts, ["face"])
      |> Enum.map(&%{label: &1, score: 0.9, box: {0, 0, 10, 10}})
    end
    defp requested(opts, owned) do
      case Keyword.get(opts, :classes, :all) do
        :all -> owned
        list -> Enum.filter(list, &(&1 in owned))
      end
    end
  end

  defmodule ObjectChild do
    @behaviour ImagePipe.Transform.Detector
    @owned ["car", "dog"]
    @impl true
    def supported_classes(_), do: @owned
    @impl true
    def available?(opts), do: Keyword.get(opts, :object_available?, true)
    @impl true
    def identity(_), do: {__MODULE__, :obj_v1}
    @impl true
    def detect(_image, opts), do: {:ok, regions_for(opts)}
    defp regions_for(opts) do
      case Keyword.get(opts, :classes, :all) do
        :all -> @owned
        list -> Enum.filter(list, &(&1 in @owned))
      end
      |> Enum.map(&%{label: &1, score: 0.8, box: {50, 50, 10, 10}})
    end
  end

  defp composite, do: Composite.new([FaceChild, ObjectChild])

  test "supported_classes is the union of children" do
    assert Enum.sort(Composite.supported_classes(composite())) == ["car", "dog", "face"]
  end

  test ":all runs every child and merges all regions" do
    {:ok, regions} = Composite.detect(composite(), :image, classes: :all)
    assert Enum.map(regions, & &1.label) |> Enum.sort() == ["car", "dog", "face"]
  end

  test "a class list routes only to the owning children" do
    {:ok, regions} = Composite.detect(composite(), :image, classes: ["face", "car"])
    assert Enum.map(regions, & &1.label) |> Enum.sort() == ["car", "face"]
  end

  test "unknown classes are dropped (best-effort)" do
    {:ok, regions} = Composite.detect(composite(), :image, classes: ["face", "unicorn"])
    assert Enum.map(regions, & &1.label) == ["face"]
  end

  test "all-unknown yields no regions and is available? = true (degrade, not fail)" do
    {:ok, regions} = Composite.detect(composite(), :image, classes: ["unicorn"])
    assert regions == []
    assert Composite.available?(composite(), classes: ["unicorn"]) == true
  end

  test "identity reflects only routed children, ordered by child order" do
    assert Composite.identity(composite(), classes: ["face"]) ==
             {Composite, [{FaceChild, :face_v1}]}

    assert Composite.identity(composite(), classes: ["car"]) ==
             {Composite, [{ObjectChild, :obj_v1}]}

    # URL order invariance: face:dog vs dog:face produce the same identity list
    assert Composite.identity(composite(), classes: ["face", "dog"]) ==
             Composite.identity(composite(), classes: ["dog", "face"])

    assert Composite.identity(composite(), classes: :all) ==
             {Composite, [{FaceChild, :face_v1}, {ObjectChild, :obj_v1}]}
  end

  test "available? requires every routed child to be available" do
    c = composite()
    assert Composite.available?(c, classes: ["face"], object_available?: false) == true
    assert Composite.available?(c, classes: ["car"], object_available?: false) == false
    assert Composite.available?(c, classes: :all, object_available?: false) == false
  end

  test "emits a per-model span per routed child with detector, model identity, and classes" do
    ref =
      :telemetry_test.attach_event_handlers(self(), [
        [:image_pipe, :transform, :detect, :model, :stop]
      ])

    on_exit(fn -> :telemetry.detach(ref) end)

    {:ok, _} =
      Composite.detect(composite(), :image,
        classes: ["face", "car"],
        telemetry_opts: [telemetry_prefix: [:image_pipe]]
      )

    assert_received {[:image_pipe, :transform, :detect, :model, :stop], ^ref, _measurements,
                     %{detector: FaceChild, model: {FaceChild, :face_v1}, classes: ["face"], regions: 1}}

    assert_received {[:image_pipe, :transform, :detect, :model, :stop], ^ref, _measurements,
                     %{detector: ObjectChild, model: {ObjectChild, :obj_v1}, classes: ["car"], regions: 1}}
  end
end
