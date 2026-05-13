defmodule ImagePlug.PlanTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Response
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Rotate

  test "represents source, image pipelines, and output separately" do
    operations = [resize_operation()]

    plan = %Plan{
      source: {:plain, ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: %Output{mode: {:explicit, :webp}}
    }

    assert plan.source == {:plain, ["images", "cat.jpg"]}
    assert [%Pipeline{operations: ^operations}] = plan.pipelines
    assert plan.output.mode == {:explicit, :webp}
  end

  test "validated pipelines accept semantic operation structs" do
    operation = resize_operation()

    plan = %Plan{
      source: {:plain, ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: [operation]}],
      output: %Output{mode: {:explicit, :webp}}
    }

    assert {:ok, [%Pipeline{operations: [^operation]}]} = Plan.validated_pipelines(plan)
  end

  test "validated pipelines accept explicit orientation primitive allowlist" do
    operations = [%AutoOrient{}, %Rotate{angle: 90}, %Flip{axis: :horizontal}]

    plan =
      plan(pipelines: [%Pipeline{operations: operations}])

    assert {:ok, [%Pipeline{operations: ^operations}]} = Plan.validated_pipelines(plan)
  end

  test "validated pipelines reject parser-local command structs" do
    operation = %ImagePlug.Parser.Imgproxy.PipelineRequest{}

    assert Plan.validated_pipelines(plan(pipelines: [%Pipeline{operations: [operation]}])) ==
             {:error, {:invalid_pipeline_operation, operation}}
  end

  test "validated pipelines reject non-orientation executable transform structs" do
    operation = %ImagePlug.Transform.Operation.Resize{
      mode: :fit,
      width: {:pixels, 100},
      height: :auto
    }

    assert Plan.validated_pipelines(plan(pipelines: [%Pipeline{operations: [operation]}])) ==
             {:error, {:invalid_pipeline_operation, operation}}
  end

  test "validated pipelines reject malformed semantic operation structs" do
    operation = %Operation.Resize{
      mode: :bogus,
      width: nil,
      height: nil,
      dpr: {:ratio, 1, 1},
      enlargement: :deny,
      guide: :center
    }

    assert Plan.validated_pipelines(plan(pipelines: [%Pipeline{operations: [operation]}])) ==
             {:error, {:invalid_pipeline_operation, operation}}
  end

  test "validate shape accepts default product-neutral facets" do
    plan = plan()

    assert {:ok, ^plan} = Plan.validate_shape(plan)
  end

  test "validate shape rejects improper plain source path without raising" do
    source = {:plain, ["images" | :bad]}

    assert Plan.validate_shape(plan(source: source)) ==
             {:error, {:unsupported_source, source}}
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

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: {:plain, ["images", "cat.jpg"]},
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
