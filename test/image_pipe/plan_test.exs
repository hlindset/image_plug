defmodule ImagePipe.PlanTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.AutoOrient
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Response
  alias ImagePipe.Plan.Source

  test "validated pipelines accept semantic operation structs" do
    operation = resize_operation()

    plan = %Plan{
      source: %Source.Path{segments: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: [operation]}],
      output: %Output{mode: {:explicit, :webp}}
    }

    assert {:ok, [%Pipeline{operations: [^operation]}]} = Plan.validated_pipelines(plan)
  end

  test "validated pipelines accept semantic orientation operations" do
    operations = [%AutoOrient{}, %Rotate{angle: 90}, %Flip{axis: :horizontal}]

    plan =
      plan(pipelines: [%Pipeline{operations: operations}])

    assert {:ok, [%Pipeline{operations: ^operations}]} = Plan.validated_pipelines(plan)
  end

  test "validate shape accepts default product-neutral facets" do
    plan = plan()

    assert {:ok, ^plan} = Plan.validate_shape(plan)
  end

  test "validate shape rejects improper path source without raising" do
    for source <- [
          %Source.Path{segments: []},
          %Source.Path{segments: ["images" | :bad]}
        ] do
      assert Plan.validate_shape(plan(source: source)) ==
               {:error, {:unsupported_source, source}}
    end
  end

  test "validate shape rejects invalid expires values" do
    for expires <- [-1, 1.5, "60", nil] do
      assert Plan.validate_shape(plan(expires: expires)) ==
               {:error, {:invalid_expires, expires}}
    end
  end

  test "validate shape rejects invalid cachebuster values" do
    for cachebuster <- [:v1, 1, []] do
      assert Plan.validate_shape(plan(cachebuster: cachebuster)) ==
               {:error, {:invalid_cachebuster, cachebuster}}
    end
  end

  test "validate shape rejects invalid response disposition values" do
    for disposition <- [:download, "attachment", nil] do
      response = %Response{disposition: disposition}

      assert Plan.validate_shape(plan(response: response)) ==
               {:error, {:invalid_response_plan, response}}
    end
  end

  test "validate shape rejects invalid response filename values" do
    for filename <- [:cat, 1, []] do
      response = %Response{filename: filename}

      assert Plan.validate_shape(plan(response: response)) ==
               {:error, {:invalid_response_plan, response}}
    end
  end

  test "validate shape rejects malformed response filename strings" do
    for filename <- [
          "",
          <<255>>,
          1,
          "a/b",
          "a\\b",
          "a\nb"
        ] do
      response = %Response{filename: filename}

      assert Plan.validate_shape(plan(response: response)) ==
               {:error, {:invalid_response_plan, response}}
    end
  end

  test "detect_classes finds a {:detect, classes} guide" do
    assert Plan.detect_classes(plan_with_guide({:detect, {["face"], %{}}})) == ["face"]
  end

  test "detect_classes returns a guide's classes sorted and deduped" do
    assert Plan.detect_classes(plan_with_guide({:detect, {["dog", "car", "dog"], %{}}})) == [
             "car",
             "dog"
           ]
  end

  test "detect_classes returns :all for an all-objects guide" do
    assert Plan.detect_classes(plan_with_guide({:detect, {:all, %{}}})) == :all
  end

  test "detect_classes is nil when no detect guide is present" do
    assert Plan.detect_classes(plan_with_guide(:center)) == nil
  end

  test "detect_classes is nil for an operation without a guide field" do
    plan = plan(pipelines: [%Pipeline{operations: [%AutoOrient{}]}])
    assert Plan.detect_classes(plan) == nil
  end

  test "face_assist? detects a {:smart, :face_assist} guide" do
    assert Plan.face_assist?(plan_with_guide({:smart, :face_assist}))
  end

  test "face_assist? is false otherwise" do
    refute Plan.face_assist?(plan_with_guide(:smart))
  end

  defp plan_with_guide(guide) do
    operation = %CropGuided{width: {:px, 10}, height: {:px, 10}, guide: guide}
    plan(pipelines: [%Pipeline{operations: [operation]}])
  end

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: %Source.Path{segments: ["images", "cat.jpg"]},
          pipelines: [%Pipeline{operations: []}],
          output: %Output{mode: :automatic}
        ],
        overrides
      )
    )
  end

  defp resize_operation do
    assert {:ok, operation} = Operation.resize(:fit, {:px, 300}, :auto, enlargement: :deny)
    operation
  end
end
