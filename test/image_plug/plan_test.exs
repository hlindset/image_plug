defmodule ImagePlug.PlanTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Cache
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Policy
  alias ImagePlug.Plan.Response
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

  test "validate shape accepts default product-neutral facets" do
    plan = plan()

    assert {:ok, ^plan} = Plan.validate_shape(plan)
  end

  test "validate shape rejects invalid policy expires values" do
    for expires <- [-1, 1.5, "60", nil] do
      policy = %Policy{expires: expires}

      assert Plan.validate_shape(plan(policy: policy)) ==
               {:error, {:invalid_policy_plan, policy}}
    end
  end

  test "validate shape rejects invalid cache cachebuster values" do
    for cachebuster <- [:v1, 1, []] do
      cache = %Cache{cachebuster: cachebuster}

      assert Plan.validate_shape(plan(cache: cache)) ==
               {:error, {:invalid_cache_plan, cache}}
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

  test "validated pipelines reject partial operation structs" do
    operation = %PartialTransform{}

    plan = %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: [operation]}],
      output: %Output{mode: {:explicit, :webp}}
    }

    assert {:error, {:invalid_pipeline_operation, ^operation}} = Plan.validated_pipelines(plan)
  end

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: %Plain{path: ["images", "cat.jpg"]},
          pipelines: [%Pipeline{operations: []}],
          output: %Output{mode: :automatic}
        ],
        overrides
      )
    )
  end
end
