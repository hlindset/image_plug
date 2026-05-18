defmodule ImagePlug.Transform.PrefetchValidationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source
  alias ImagePlug.Transform
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.Operation.Rotate

  test "semantic Plan operations pass source-independent validation" do
    assert {:ok, operation} = Operation.resize(:auto, {:px, 100}, {:px, 100}, enlargement: :deny)

    assert {:ok, [%Pipeline{operations: [^operation]}]} =
             Transform.validate_prefetch_safe_plan(plan([operation]))
  end

  test "crop regions are prefetch-safe semantic operations" do
    operation = crop_region_operation()

    assert {:ok, [%Pipeline{operations: [^operation]}]} =
             Transform.validate_prefetch_safe_plan(plan([operation]))
  end

  test "crop regions after prior geometry remain current-image-relative operations" do
    resize = resize_operation()
    crop = crop_region_operation()

    assert {:ok, [%Pipeline{operations: [^resize, ^crop]}]} =
             Transform.validate_prefetch_safe_plan(plan([resize, crop]))
  end

  test "executable orientation primitives pass source-independent validation" do
    operations = [%AutoOrient{}, %Rotate{angle: 90}, %Flip{axis: :horizontal}]

    assert {:ok, [%Pipeline{operations: ^operations}]} =
             Transform.validate_prefetch_safe_plan(plan(operations))
  end

  test "non-orientation executable transforms fail source-independent validation" do
    operation = %Resize{mode: :fit, width: {:pixels, 100}, height: :auto}

    assert Transform.validate_prefetch_safe_plan(plan([operation])) ==
             {:error, {:invalid_pipeline_operation, operation}}
  end

  defp plan(operations) do
    %Plan{
      source: %Source.Path{segments: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: %Output{mode: {:explicit, :jpeg}}
    }
  end

  defp resize_operation do
    {:ok, operation} = Operation.resize(:fit, {:px, 100}, {:px, 100}, enlargement: :deny)
    operation
  end

  defp crop_region_operation do
    {:ok, operation} = Operation.crop_region({:px, 1}, {:px, 1}, {:px, 10}, {:px, 10})
    operation
  end
end
