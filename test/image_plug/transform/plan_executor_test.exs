defmodule ImagePlug.Transform.PlanExecutorTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Transform
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Rotate
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
                   []
                 )

        assert dimensions(state.image) == expected_dimensions
      end
    end

    test "resize cover applies offsets to the result crop" do
      assert {:ok, operation} =
               Operation.resize(:cover, {:px, 100}, {:px, 100},
                 enlargement: :allow,
                 guide: {:anchor, :left, :center},
                 x_offset: {:pixels, 200}
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([operation]),
                 state_with_wide_offset_image(),
                 []
               )

      assert dimensions(state.image) == {100, 100}
      assert Image.get_pixel!(state.image, 50, 50) == [0, 0, 255]
    end
  end

  describe "crop execution" do
    test "crop guided executes gravity crop against the current image" do
      assert {:ok, operation} = Operation.crop_guided({:px, 120}, {:px, 80}, :bottom_right)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([operation]),
                 state_with_image(300, 200),
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
                 []
               )

      assert dimensions(state.image) == {133, 100}
    end
  end

  describe "composition execution" do
    test "padding expands dimensions and places the source image by left and top" do
      assert {:ok, padding} =
               Operation.padding({:px, 1}, {:px, 2}, {:px, 3}, {:px, 4})

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([padding]), state_with_split_image(), [])

      assert dimensions(state.image) == {8, 5}
      assert rgb_pixel(state.image, 4, 1) == [255, 0, 0]
      assert rgb_pixel(state.image, 5, 1) == [0, 0, 255]
    end

    test "padding scales sides with round-half-to-even" do
      assert {:ok, padding} =
               Operation.padding({:px, 1}, {:px, 3}, {:px, 5}, {:px, 7},
                 pixel_ratio: {:ratio, 1, 2}
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([padding]), state_with_image(10, 10), [])

      assert dimensions(state.image) == {16, 12}
    end

    test "transparent padding over an RGB source preserves alpha in generated pixels" do
      assert {:ok, padding} = Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 1})

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([padding]), state_with_image(2, 2), [])

      assert alpha_value(state.image, 0, 0) == 0
    end

    test "flatten background composites transparent generated pixels without changing dimensions" do
      assert {:ok, padding} = Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 1})
      assert {:ok, red} = Operation.color(255, 0, 0)
      assert {:ok, flatten} = Operation.flatten_background(red)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([padding, flatten]), state_with_image(2, 2), [])

      assert dimensions(state.image) == {3, 3}
      assert rgb_pixel(state.image, 0, 0) == [255, 0, 0]
      assert is_nil(Enum.at(Image.get_pixel!(state.image, 0, 0), 3))
    end

    test "transparent canvas over an RGB source preserves alpha in generated pixels" do
      assert {:ok, canvas} = Operation.canvas({:px, 4}, {:px, 4}, :center)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([canvas]), state_with_image(2, 2), [])

      assert alpha_value(state.image, 0, 0) == 0
    end
  end

  describe "orientation primitives" do
    test "auto orient, rotate, and flip execute as allowed primitive operations" do
      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([%AutoOrient{}, %Rotate{angle: 90}]),
                 state_with_image(80, 40),
                 []
               )

      assert dimensions(state.image) == {40, 80}

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([%Flip{axis: :horizontal}]),
                 state_with_split_image(),
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

    assert {:ok, %State{} = state} =
             Transform.execute_plan(plan([operation]), state, [])

    assert dimensions(state.image) == {300, 200}
  end

  for {source, target, expected_dimensions, visible_crop?} <- [
        {{1600, 900}, {300, 200}, {300, 200}, true},
        {{1600, 900}, {200, 300}, {200, 113}, false},
        {{1000, 1000}, {300, 300}, {300, 300}, false},
        {{1000, 1000}, {300, 200}, {200, 200}, false}
      ] do
    test "resize auto #{inspect(source)} to #{inspect(target)} returns #{inspect(expected_dimensions)}" do
      source = unquote(Macro.escape(source))
      {target_width, target_height} = unquote(Macro.escape(target))
      expected_dimensions = unquote(Macro.escape(expected_dimensions))
      visible_crop? = unquote(visible_crop?)

      assert {:ok, operation} =
               Operation.resize(:auto, {:px, target_width}, {:px, target_height},
                 enlargement: :allow
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([operation]),
                 state_with_resize_auto_source(source),
                 []
               )

      assert dimensions(state.image) == expected_dimensions
      assert_resize_auto_visible_crop(visible_crop?, state.image)
    end
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
               []
             )

    assert dimensions(state.image) == {100, 200}
  end

  test "resize auto cover branch applies offsets to the result crop" do
    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 100}, {:px, 50},
               enlargement: :allow,
               guide: {:anchor, :left, :center},
               x_offset: {:pixels, 50}
             )

    assert {:ok, %State{} = state} =
             Transform.execute_plan(
               plan([operation]),
               state_with_wide_offset_image(),
               []
             )

    assert dimensions(state.image) == {100, 50}
    assert Image.get_pixel!(state.image, 75, 25) == [0, 0, 255]
  end

  defp plan(operations) do
    %Plan{
      source: {:plain, ["images", "cat.jpg"]},
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

  defp state_with_wide_offset_image do
    image =
      300
      |> Image.new!(100, color: :red)
      |> Image.Draw.rect!(200, 0, 100, 100, color: :blue)

    %State{image: image}
  end

  defp state_with_resize_auto_source({1600, 900}) do
    image =
      1600
      |> Image.new!(900, color: :white)
      |> Image.Draw.rect!(0, 0, 90, 900, color: :red)
      |> Image.Draw.rect!(1510, 0, 90, 900, color: :blue)

    %State{image: image}
  end

  defp state_with_resize_auto_source(source), do: state_with_image(source)

  defp rgb_pixel(image, x, y) do
    image
    |> Image.get_pixel!(x, y)
    |> Enum.take(3)
  end

  defp alpha_value(image, x, y) do
    image
    |> Image.get_pixel!(x, y)
    |> Enum.at(3)
  end

  defp assert_resize_auto_visible_crop(true, image) do
    assert Image.get_pixel!(image, 0, div(Image.height(image), 2)) == [255, 255, 255]

    assert Image.get_pixel!(image, Image.width(image) - 1, div(Image.height(image), 2)) == [
             255,
             255,
             255
           ]
  end

  defp assert_resize_auto_visible_crop(false, _image), do: :ok

  defp dimensions(image), do: {Image.width(image), Image.height(image)}
end
