defmodule ImagePlug.PlanTest do
  use ExUnit.Case, async: true

  alias ImagePlug.OutputPlan
  alias ImagePlug.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.Source.Plain
  alias ImagePlug.Transform

  defmodule PartialTransform do
    defstruct []

    def new(attrs), do: {:ok, new!(attrs)}
    def new!(%__MODULE__{} = operation), do: operation
    def new!(attrs), do: struct!(__MODULE__, attrs)
    def name(%__MODULE__{}), do: :partial
    def execute(%__MODULE__{}, state), do: state
  end

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
      output: %OutputPlan{mode: {:explicit, :webp}}
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
      output: %OutputPlan{mode: {:explicit, :webp}}
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
      output: %OutputPlan{mode: {:explicit, :webp}}
    }

    assert {:error, {:invalid_pipeline_operation, ^operation}} = Plan.validated_pipelines(plan)
  end

  test "validated pipelines reject partial operation structs" do
    operation = %PartialTransform{}

    plan = %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: [operation]}],
      output: %OutputPlan{mode: {:explicit, :webp}}
    }

    assert {:error, {:invalid_pipeline_operation, ^operation}} = Plan.validated_pipelines(plan)
  end
end
