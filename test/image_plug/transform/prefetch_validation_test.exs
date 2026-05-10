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

  test "source-space crop regions are valid at the start of a first-slice pipeline" do
    operation = source_crop_region_operation()

    assert {:ok, [%Pipeline{operations: [^operation]}]} =
             Transform.validate_prefetch_safe_plan(plan([operation]))
  end

  test "source-space crop regions reject zero-sized ratio dimensions" do
    assert {:ok, zero} = Dimension.ratio(0, 1)
    assert {:ok, x} = Dimension.ratio(0, 1)
    assert {:ok, y} = Dimension.ratio(0, 1)
    assert {:ok, positive} = Dimension.ratio(1, 2)

    for attrs <- [
          [x: x, y: y, width: zero, height: positive, space: :source],
          [x: x, y: y, width: positive, height: zero, space: :source]
        ] do
      assert {:ok, region} = Region.new(attrs)
      assert {:ok, operation} = Operation.crop_region(region: region)

      assert Transform.validate_prefetch_safe_plan(plan([operation])) ==
               {:error, {:invalid_pipeline_operation, operation}}
    end
  end

  test "source-space crop regions allow zero pixel coordinates but reject zero pixel dimensions" do
    assert {:ok, zero} = Dimension.pixels(0)
    assert {:ok, width} = Dimension.pixels(100)
    assert {:ok, height} = Dimension.pixels(50)

    assert {:ok, valid_region} =
             Region.new(x: zero, y: zero, width: width, height: height, space: :source)

    assert {:ok, valid_operation} = Operation.crop_region(region: valid_region)

    assert {:ok, [%Pipeline{operations: [^valid_operation]}]} =
             Transform.validate_prefetch_safe_plan(plan([valid_operation]))

    for attrs <- [
          [x: zero, y: zero, width: zero, height: height, space: :source],
          [x: zero, y: zero, width: width, height: zero, space: :source]
        ] do
      assert {:ok, region} = Region.new(attrs)
      assert {:ok, operation} = Operation.crop_region(region: region)

      assert Transform.validate_prefetch_safe_plan(plan([operation])) ==
               {:error, {:invalid_pipeline_operation, operation}}
    end
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

  test "unsupported first-slice guide spaces fail source-independent validation" do
    for space <- [:source, :post_orient],
        operation <- guided_operations(space) do
      assert Transform.validate_prefetch_safe_plan(plan([operation])) ==
               {:error, {:invalid_pipeline_operation, operation}}
    end
  end

  test "current-space guide defaults pass source-independent validation" do
    for operation <- guided_operations(:current) do
      assert {:ok, [%Pipeline{operations: [^operation]}]} =
               Transform.validate_prefetch_safe_plan(plan([operation]))
    end
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

  defp guided_operations(space) do
    {:ok, guide} = Gravity.focal_point(1, 4, 3, 4, space)
    {:ok, crop_guided} = Operation.crop_guided(size: size(), guide: guide)
    {:ok, resize_cover} = Operation.resize_cover(size: size(), enlargement: :deny, guide: guide)
    {:ok, resize_auto} = Operation.resize_auto(size: size(), enlargement: :deny, guide: guide)

    {:ok, canvas} =
      Operation.canvas(
        size: size(),
        placement: guide,
        background: :white,
        overflow: :reject
      )

    [crop_guided, resize_cover, resize_auto, canvas]
  end

  defp size(width, height) do
    {:ok, width} = Dimension.pixels(width)
    {:ok, height} = Dimension.pixels(height)
    Size.new(width: width, height: height, dpr: 1.0)
  end
end
