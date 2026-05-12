defmodule ImagePlug.Transform.PlanExecutorTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Rotate
  alias ImagePlug.Transform.SourceMetadata
  alias ImagePlug.Transform.State

  describe "resize execution" do
    test "resize fit, cover, and stretch execute through existing visible behavior" do
      cases = [
        {:fit, {:px, 100}, {:px, 100}, {300, 200}, {100, 67}},
        {:cover, {:px, 100}, {:px, 50}, {300, 200}, {100, 50}},
        {:stretch, :auto, {:px, 100}, {300, 200}, {300, 100}}
      ]

      for {mode, width, height, source_dimensions, expected_dimensions} <- cases do
        assert {:ok, operation} = Operation.resize(mode, width, height, enlargement: :allow)

        assert {:ok, %State{} = state} =
                 Transform.execute_plan(
                   plan([operation]),
                   state_with_image(source_dimensions),
                   metadata(),
                   []
                 )

        assert dimensions(state.image) == expected_dimensions
      end
    end
  end

  describe "crop execution" do
    test "crop guided executes gravity crop against the current image" do
      assert {:ok, operation} = Operation.crop_guided({:px, 120}, {:px, 80}, :bottom_right)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([operation]),
                 state_with_image(300, 200),
                 metadata(),
                 []
               )

      assert dimensions(state.image) == {120, 80}
    end

    test "crop region ratios resolve against actual current dimensions" do
      assert {:ok, resize} =
               Operation.resize(:stretch, {:px, 400}, {:px, 300}, enlargement: :allow)

      assert {:ok, crop} =
               Operation.crop_region(
                 {:ratio, 1, 4},
                 {:ratio, 1, 3},
                 {:ratio, 1, 2},
                 {:ratio, 1, 3}
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([resize, crop]),
                 state_with_image(800, 600),
                 metadata(),
                 []
               )

      assert dimensions(state.image) == {200, 100}
    end
  end

  describe "canvas execution" do
    test "canvas supports pixel and auto geometry" do
      assert {:ok, operation} = Operation.canvas({:px, 120}, :auto, :center)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([operation]),
                 state_with_image(100, 50),
                 metadata(),
                 []
               )

      assert dimensions(state.image) == {120, 50}
    end

    test "canvas supports ratio geometry" do
      assert {:ok, operation} = Operation.canvas({:ratio, 4, 3}, {:ratio, 1, 1}, :center)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([operation]),
                 state_with_image(100, 100),
                 metadata(),
                 []
               )

      assert dimensions(state.image) == {133, 100}
    end
  end

  describe "orientation primitives" do
    test "auto orient, rotate, and flip execute as allowed primitive operations" do
      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([%AutoOrient{}, %Rotate{angle: 90}]),
                 state_with_image(80, 40),
                 metadata(),
                 []
               )

      assert dimensions(state.image) == {40, 80}

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([%Flip{axis: :horizontal}]),
                 state_with_split_image(),
                 metadata(),
                 []
               )

      assert Image.get_pixel!(state.image, 0, 0) == [0, 0, 255]
      assert Image.get_pixel!(state.image, 1, 0) == [255, 0, 0]
    end
  end

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

  defp state_with_image({width, height}), do: state_with_image(width, height)

  defp state_with_image(width, height) do
    {:ok, image} = Image.new(width, height, color: :white)
    %State{image: image}
  end

  defp state_with_split_image do
    image =
      2
      |> Image.new!(1, color: :black)
      |> Image.Draw.rect!(0, 0, 1, 1, color: :red)
      |> Image.Draw.rect!(1, 0, 1, 1, color: :blue)

    %State{image: image}
  end

  defp metadata do
    {:ok, metadata} = SourceMetadata.new(format: :jpeg, source_type: :raster)
    metadata
  end

  defp dimensions(image), do: {Image.width(image), Image.height(image)}
end
