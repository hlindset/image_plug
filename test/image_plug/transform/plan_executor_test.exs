defmodule ImagePlug.Transform.PlanExecutorTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform
  alias ImagePlug.Transform.SourceMetadata
  alias ImagePlug.Transform.State

  test "resize auto executes against current image state" do
    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 300}, {:px, 200}, enlargement: :deny)

    state = state_with_image(1600, 900)
    metadata = metadata()

    assert {:ok, %State{} = state} =
             Transform.execute_plan(plan([operation]), state, metadata, [])

    assert dimensions(state.image) == {300, 200}
  end

  test "ordered resize then ratio crop uses actual post-resize dimensions" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 300}, {:px, 200}, enlargement: :deny)

    assert {:ok, crop} =
             Operation.crop_region(
               {:ratio, 1, 10},
               {:ratio, 1, 10},
               {:ratio, 1, 2},
               {:ratio, 1, 2}
             )

    assert {:ok, %State{} = state} =
             Transform.execute_plan(
               plan([resize, crop]),
               state_with_image(600, 400),
               metadata(),
               []
             )

    assert dimensions(state.image) == {150, 100}
  end

  test "resize auto observes dimensions changed by earlier operations" do
    assert {:ok, crop} = Operation.crop_region({:px, 0}, {:px, 0}, {:px, 200}, {:px, 400})
    assert {:ok, resize} = Operation.resize(:auto, {:px, 300}, {:px, 200}, enlargement: :deny)

    assert {:ok, %State{} = state} =
             Transform.execute_plan(
               plan([crop, resize]),
               state_with_image(600, 400),
               metadata(),
               []
             )

    assert dimensions(state.image) == {100, 200}
  end

  defp plan(operations) do
    %Plan{
      source: %Plain{path: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: %ImagePlug.Plan.Output{mode: {:explicit, :jpeg}}
    }
  end

  defp state_with_image(width, height) do
    {:ok, image} = Image.new(width, height, color: :white)
    %State{image: image}
  end

  defp metadata do
    {:ok, metadata} = SourceMetadata.new(format: :jpeg, source_type: :raster)
    metadata
  end

  defp dimensions(image), do: {Image.width(image), Image.height(image)}
end
