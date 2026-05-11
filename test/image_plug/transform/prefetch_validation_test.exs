defmodule ImagePlug.Transform.PrefetchValidationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Region
  alias ImagePlug.Plan.Geometry.Size
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

  test "source-space crop regions are valid at the start of a first-slice pipeline" do
    operation = source_crop_region_operation()

    assert {:ok, [%Pipeline{operations: [^operation]}]} =
             Transform.validate_prefetch_safe_plan(plan([operation]))
  end

  test "source-space crop regions after prior geometry fail source-independent validation" do
    resize = resize_fit_operation()
    crop = source_crop_region_operation()

    assert Transform.validate_prefetch_safe_plan(plan([resize, crop])) ==
             {:error, {:invalid_pipeline_operation, crop}}
  end

  test "source-space crop after source-sized resize is rejected before no-op evaluation" do
    resize = resize_fit_operation(300, 200)
    crop = source_crop_region_operation()

    # Conservative first-slice policy is positional: prior geometry makes source-space ambiguous,
    # even when source metadata could later prove the resize is an identity operation.
    assert Transform.validate_prefetch_safe_plan(plan([resize, crop])) ==
             {:error, {:invalid_pipeline_operation, crop}}
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

  defp resize_fit_operation do
    resize_fit_operation(100, 100)
  end

  defp resize_fit_operation(width, height) do
    {:ok, operation_size} = size(width, height)
    {:ok, operation} = Operation.resize_fit(size: operation_size, enlargement: :deny)
    operation
  end

  defp source_crop_region_operation do
    {:ok, x} = Dimension.pixels(1)
    {:ok, y} = Dimension.pixels(1)
    {:ok, width} = Dimension.pixels(10)
    {:ok, height} = Dimension.pixels(10)
    {:ok, region} = Region.new(x: x, y: y, width: width, height: height, space: :source)
    {:ok, operation} = Operation.crop_region(region: region)
    operation
  end

  defp size(width, height) do
    {:ok, width} = Dimension.pixels(width)
    {:ok, height} = Dimension.pixels(height)
    Size.new(width: width, height: height, dpr: 1.0)
  end
end
