defmodule ImagePlug.PlanTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.PlanTest.PartialTransform
  alias ImagePlug.PlanTest.RuntimeOnlyTransform
  alias ImagePlug.Transform

  test "represents source, image pipelines, and output separately" do
    operations = [
      %Transform.Contain{
        type: :dimensions,
        width: {:pixels, 300},
        height: :auto,
        constraint: :max,
        letterbox: false
      }
    ]

    plan = %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: %Output{mode: {:explicit, :webp}}
    }

    assert plan.source.path == ["images", "cat.jpg"]
    assert [%Pipeline{operations: ^operations}] = plan.pipelines
    assert plan.output.mode == {:explicit, :webp}
  end

  test "validated pipelines accept transform operation structs" do
    operation = %Transform.Scale{
      type: :dimensions,
      width: {:pixels, 300},
      height: :auto
    }

    plan = %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: [operation]}],
      output: %Output{mode: {:explicit, :webp}}
    }

    assert {:ok, [%Pipeline{operations: [^operation]}]} = Plan.validated_pipelines(plan)
  end

  test "validated pipelines accept runtime-only operation structs" do
    operation = %RuntimeOnlyTransform{}

    plan = %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: [operation]}],
      output: %Output{mode: {:explicit, :webp}}
    }

    assert {:ok, [%Pipeline{operations: [^operation]}]} = Plan.validated_pipelines(plan)
  end

  test "validated pipelines reject old transform tuple operations" do
    operation = {
      Transform.Scale,
      %{type: :dimensions, width: {:pixels, 300}, height: :auto}
    }

    plan = %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: [operation]}],
      output: %Output{mode: {:explicit, :webp}}
    }

    assert {:error, {:invalid_pipeline_operation, ^operation}} = Plan.validated_pipelines(plan)
  end

  test "validated pipelines reject partial operation structs" do
    operation = %PartialTransform{}

    plan = %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: [operation]}],
      output: %Output{mode: {:explicit, :webp}}
    }

    assert {:error, {:invalid_pipeline_operation, ^operation}} = Plan.validated_pipelines(plan)
  end
end
