defmodule ImagePlug.PlanTest do
  use ExUnit.Case, async: true

  alias ImagePlug.OutputPlan
  alias ImagePlug.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.Source.Plain
  alias ImagePlug.Transform

  test "represents source, image pipelines, and output separately" do
    operations = [
      {Transform.Contain,
       %Transform.Contain.ContainParams{
         type: :dimensions,
         width: {:pixels, 300},
         height: :auto,
         constraint: :max,
         letterbox: false
       }}
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
end
