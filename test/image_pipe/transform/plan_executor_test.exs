defmodule ImagePipe.Transform.PlanExecutorTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.AutoOrient
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source
  alias ImagePipe.Transform
  alias ImagePipe.Transform.State

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

    test "opaque background composites transparent generated pixels without changing dimensions" do
      assert {:ok, padding} = Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 1})
      assert {:ok, red} = Operation.color(255, 0, 0)
      assert {:ok, background} = Operation.background(red)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([padding, background]), state_with_image(2, 2), [])

      assert dimensions(state.image) == {3, 3}
      assert rgb_pixel(state.image, 0, 0) == [255, 0, 0]
      assert is_nil(Enum.at(Image.get_pixel!(state.image, 0, 0), 3))
    end

    test "alpha background preserves output alpha for alpha-capable encoders" do
      assert {:ok, padding} = Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 1})
      assert {:ok, red} = Operation.color(255, 0, 0, {:ratio, 1, 2})
      assert {:ok, background} = Operation.background(red)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([padding, background]), state_with_image(2, 2), [])

      assert dimensions(state.image) == {3, 3}
      assert Image.get_pixel!(state.image, 0, 0) == [255, 0, 0, 128]
    end

    test "transparent canvas over an RGB source preserves alpha in generated pixels" do
      assert {:ok, canvas} = Operation.canvas({:px, 4}, {:px, 4}, :center)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([canvas]), state_with_image(2, 2), [])

      assert alpha_value(state.image, 0, 0) == 0
    end

    test "alpha solid canvas fill preserves alpha in generated pixels" do
      assert {:ok, red} = Operation.color(255, 0, 0, {:ratio, 1, 2})
      assert {:ok, canvas} = Operation.canvas({:px, 4}, {:px, 4}, :center, fill: {:solid, red})

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([canvas]), state_with_image(2, 2), [])

      assert Image.get_pixel!(state.image, 0, 0) == [255, 0, 0, 128]
    end

    test "padding after resize keeps explicit pixel ratio authoritative" do
      assert {:ok, resize} =
               Operation.resize(:fit, {:px, 1000}, :auto, dpr: 2.0, enlargement: :deny)

      assert {:ok, padding} =
               Operation.padding({:px, 10}, {:px, 0}, {:px, 0}, {:px, 0},
                 pixel_ratio: {:ratio, 2, 1}
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([resize, padding]), state_with_image(100, 50), [])

      assert dimensions(state.image) == {100, 70}
    end

    test "effective padding after no-enlarge resize uses effective DPR" do
      assert {:ok, resize} =
               Operation.resize(:fit, {:px, 1000}, :auto, dpr: 2.0, enlargement: :deny)

      assert {:ok, padding} =
               Operation.padding({:px, 10}, {:px, 0}, {:px, 0}, {:px, 0},
                 pixel_ratio: {:effective, {:ratio, 2, 1}, :resize}
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([resize, padding]), state_with_image(100, 50), [])

      assert dimensions(state.image) == {100, 60}
    end

    test "canvas-preserving effective padding skips no-enlarge DPR compensation" do
      assert {:ok, resize} =
               Operation.resize(:fit, {:px, 200}, {:px, 100},
                 dpr: 0.5,
                 enlargement: :deny
               )

      assert {:ok, canvas} = Operation.canvas({:px, 200}, {:px, 100}, :center)

      assert {:ok, padding} =
               Operation.padding({:px, 10}, {:px, 0}, {:px, 0}, {:px, 0},
                 pixel_ratio: {:effective, {:ratio, 1, 2}, :canvas_preserving}
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(
                 plan([resize, canvas, padding]),
                 state_with_image(100, 50),
                 []
               )

      assert dimensions(state.image) == {200, 105}
    end

    test "padding without a preceding resize uses requested pixel ratio" do
      assert {:ok, padding} =
               Operation.padding({:px, 10}, {:px, 0}, {:px, 0}, {:px, 0},
                 pixel_ratio: {:ratio, 2, 1}
               )

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([padding]), state_with_image(100, 50), [])

      assert dimensions(state.image) == {100, 70}
    end
  end

  describe "multi-pipeline plan execution" do
    test "materialized? threads from pipeline 1 into pipeline 2" do
      pipeline1 = %Pipeline{operations: [%Rotate{angle: 90}]}
      pipeline2 = %Pipeline{operations: [%Rotate{angle: 90}]}

      multi_plan = %Plan{
        source: %Source.Path{segments: ["images", "cat.jpg"]},
        pipelines: [pipeline1, pipeline2],
        output: %ImagePipe.Plan.Output{mode: {:explicit, :jpeg}}
      }

      assert {:ok, %State{} = state} =
               Transform.execute_plan(multi_plan, state_with_image(40, 20), [])

      assert state.materialized? == true
      assert Image.width(state.image) == 40
      assert Image.height(state.image) == 20
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

  describe "effect execution" do
    test "blur softens hard color boundaries without changing dimensions" do
      assert {:ok, blur} = Operation.blur(2.0)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([blur]), state_with_split_image(), [])

      assert dimensions(state.image) == {2, 1}
      assert rgb_pixel(state.image, 0, 0) != [255, 0, 0]
      assert rgb_pixel(state.image, 1, 0) != [0, 0, 255]
    end

    test "sharpen preserves dimensions" do
      assert {:ok, sharpen} = Operation.sharpen(1.0)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([sharpen]), state_with_image(20, 20), [])

      assert dimensions(state.image) == {20, 20}
    end

    test "pixelate groups pixels using the requested block size" do
      assert {:ok, pixelate} = Operation.pixelate(2)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([pixelate]), state_with_striped_image(), [])

      assert dimensions(state.image) == {4, 2}
      assert rgb_pixel(state.image, 0, 0) == rgb_pixel(state.image, 1, 0)
      assert rgb_pixel(state.image, 2, 0) == rgb_pixel(state.image, 3, 0)
    end

    test "pixelate preserves dimensions for non-divisible and oversized block sizes" do
      assert {:ok, non_divisible} = Operation.pixelate(2)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([non_divisible]), state_with_image(5, 3), [])

      assert dimensions(state.image) == {5, 3}

      assert {:ok, oversized} = Operation.pixelate(100)

      assert {:ok, %State{} = state} =
               Transform.execute_plan(plan([oversized]), state_with_image(10, 10), [])

      assert dimensions(state.image) == {10, 10}
    end

    test "brightness contrast and saturation preserve dimensions and change pixels" do
      baseline = state_with_adjustment_image()

      for build_operation <- [
            &Operation.brightness/1,
            &Operation.contrast/1,
            &Operation.saturation/1
          ] do
        assert {:ok, operation} = build_operation.(25)

        assert {:ok, %State{} = state} =
                 Transform.execute_plan(plan([operation]), state_with_adjustment_image(), [])

        assert dimensions(state.image) == dimensions(baseline.image)
        assert rgb_pixel(state.image, 0, 0) != rgb_pixel(baseline.image, 0, 0)
      end
    end

    test "monochrome and duotone preserve dimensions and change pixels" do
      baseline = state_with_adjustment_image()
      assert {:ok, tint} = Operation.color(255, 204, 0)
      assert {:ok, shadow} = Operation.color(17, 34, 51)
      assert {:ok, highlight} = Operation.color(255, 238, 204)

      for operation <- [
            Operation.monochrome({:ratio, 1, 1}, tint),
            Operation.duotone({:ratio, 1, 1}, shadow, highlight)
          ] do
        assert {:ok, operation} = operation

        assert {:ok, %State{} = state} =
                 Transform.execute_plan(plan([operation]), state_with_adjustment_image(), [])

        assert dimensions(state.image) == dimensions(baseline.image)
        assert rgb_pixel(state.image, 0, 0) != rgb_pixel(baseline.image, 0, 0)
      end
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
      source: %Source.Path{segments: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: %ImagePipe.Plan.Output{mode: {:explicit, :jpeg}}
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

  defp state_with_striped_image do
    image =
      4
      |> Image.new!(2, color: :black)
      |> Image.Draw.rect!(0, 0, 1, 2, color: :red)
      |> Image.Draw.rect!(1, 0, 1, 2, color: :green)
      |> Image.Draw.rect!(2, 0, 1, 2, color: :blue)
      |> Image.Draw.rect!(3, 0, 1, 2, color: :white)

    %State{image: image}
  end

  defp state_with_adjustment_image do
    image =
      2
      |> Image.new!(1, color: [128, 96, 64])
      |> Image.Draw.rect!(1, 0, 1, 1, color: [64, 96, 128])

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
