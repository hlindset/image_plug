defmodule ImagePlug.Transform.PrefetchValidationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Parser.Imgproxy.PipelineRequest
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Region
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Guide.Gravity
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform

  test "semantic Plan operations pass source-independent validation" do
    assert {:ok, operation} = Operation.resize_auto(size: size(), enlargement: :deny)

    assert {:ok, [%Pipeline{operations: [^operation]}]} =
             Transform.validate_prefetch_safe_plan(plan([operation]))
  end

  test "malformed semantic Plan operations fail source-independent validation" do
    operation = %Operation.ResizeAuto{size: :not_size, enlargement: :deny}

    assert Transform.validate_prefetch_safe_plan(plan([operation])) ==
             {:error, {:invalid_pipeline_operation, operation}}
  end

  test "unsupported first-slice semantic regions fail source-independent validation" do
    assert {:ok, x} = Dimension.pixels(1)
    assert {:ok, y} = Dimension.pixels(1)
    assert {:ok, width} = Dimension.pixels(10)
    assert {:ok, height} = Dimension.pixels(10)

    region = %Region{x: x, y: y, width: width, height: height, space: :post_orient}
    assert {:ok, operation} = Operation.crop_region(region: region)

    assert Transform.validate_prefetch_safe_plan(plan([operation])) ==
             {:error, {:invalid_pipeline_operation, operation}}
  end

  test "unsupported first-slice resize dimensions fail source-independent validation" do
    assert {:ok, width} = Dimension.ratio(1, 2)
    assert {:ok, height} = Dimension.pixels(100)
    assert {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    assert {:ok, operation} = Operation.resize_fit(size: size, enlargement: :deny)

    assert Transform.validate_prefetch_safe_plan(plan([operation])) ==
             {:error, {:invalid_pipeline_operation, operation}}
  end

  test "unsupported first-slice focal point dimensions fail source-independent validation" do
    assert {:ok, point} = Dimension.pixels(10)
    gravity = %Gravity{type: :focal_point, x: point, y: point, space: :current}
    assert {:ok, operation} = Operation.crop_guided(size: size(), guide: gravity)

    assert Transform.validate_prefetch_safe_plan(plan([operation])) ==
             {:error, {:invalid_pipeline_operation, operation}}
  end

  test "parser-local command structs fail source-independent validation" do
    operation = %PipelineRequest{}

    assert Transform.validate_prefetch_safe_plan(plan([operation])) ==
             {:error, {:invalid_pipeline_operation, operation}}
  end

  test "runtime transform operations fail source-independent validation after parser migration" do
    operation = %ImagePlug.Transform.Operation.Resize{
      rule: %ImagePlug.Transform.Geometry.DimensionRule{
        mode: :fit,
        width: {:pixels, 100},
        height: :auto
      }
    }

    assert Transform.validate_prefetch_safe_plan(plan([operation])) ==
             {:error, {:invalid_pipeline_operation, operation}}
  end

  defp plan(operations) do
    %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: %Output{mode: {:explicit, :jpeg}}
    }
  end

  defp size do
    {:ok, width} = Dimension.pixels(100)
    {:ok, height} = Dimension.pixels(100)
    {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    size
  end
end
