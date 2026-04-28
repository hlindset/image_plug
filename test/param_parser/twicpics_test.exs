defmodule ImagePlug.TwicpicsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ImagePlug.TestSupport

  alias ImagePlug.Transform
  alias ImagePlug.TransformChain
  alias ImagePlug.TransformState
  alias ImagePlug.ParamParser.Twicpics

  test "parse from string" do
    result = Twicpics.parse_string("v1/focus=(1/2)sx(2/3)s/crop=100x100/resize=200/output=avif")

    assert result ==
             {:ok,
              [
                {Transform.Focus,
                 %Transform.Focus.FocusParams{
                   type: {
                     :coordinate,
                     {:scale, 1 / 2},
                     {:scale, 2 / 3}
                   }
                 }},
                {Transform.Crop,
                 %Transform.Crop.CropParams{
                   width: {:pixels, 100},
                   height: {:pixels, 100},
                   crop_from: :focus
                 }},
                {Transform.Scale,
                 %Transform.Scale.ScaleParams{
                   type: :dimensions,
                   width: {:pixels, 200},
                   height: :auto
                 }},
                {Transform.Output,
                 %Transform.Output.OutputParams{
                   format: :avif
                 }}
              ]}
  end

  test "crop transform" do
    {:ok, blank_image} = Image.new(200, 200, color: :misty_rose)
    initial_state = %TransformState{image: blank_image}

    check all focus_type <- one_of([constant(nil), focus_type()]),
              width <- random_root_unit(min: 1),
              height <- random_root_unit(min: 1),
              crop_from <- crop_from() do
      transform_chain =
        [
          if(focus_type, do: {Transform.Focus, %Transform.Focus.FocusParams{type: focus_type}}),
          {Transform.Crop,
           %Transform.Crop.CropParams{width: width, height: height, crop_from: crop_from}}
        ]
        |> Enum.reject(&is_nil/1)

      {:ok, result_state} = TransformChain.execute(initial_state, transform_chain)

      assert result_state.focus == {:anchor, :center, :center}
    end
  end

  test "implements the parser behaviour used by the plug" do
    conn =
      Plug.Test.conn(
        :get,
        "/process/images/cat-300.jpg?twic=v1/resize=100/output=webp"
      )

    assert {:ok,
            [
              {Transform.Scale, %Transform.Scale.ScaleParams{}},
              {Transform.Output, %Transform.Output.OutputParams{format: :webp}}
            ]} = Twicpics.parse(conn)
  end

  test "focus does not draw a debug dot by default" do
    {:ok, image} = Image.new(20, 20, color: :white)

    result =
      %TransformState{image: image}
      |> Transform.Focus.execute(%Transform.Focus.FocusParams{type: {:anchor, :center, :center}})

    assert Image.get_pixel!(result.image, 10, 10) == [255, 255, 255]
    assert result.focus == {:anchor, :center, :center}
  end

  test "cover-max does not request a crop larger than the unscaled image" do
    {:ok, image} = Image.new(100, 100, color: :white)

    state =
      Transform.Cover.execute(%TransformState{image: image}, %Transform.Cover.CoverParams{
        type: :dimensions,
        width: {:pixels, 200},
        height: {:pixels, 200},
        constraint: :max
      })

    assert state.errors == []
    assert {Image.width(state.image), Image.height(state.image)} == {100, 100}
  end

  test "cover-max preserves requested ratio when it cannot upscale" do
    {:ok, image} = Image.new(100, 100, color: :white)

    state =
      Transform.Cover.execute(%TransformState{image: image}, %Transform.Cover.CoverParams{
        type: :dimensions,
        width: {:pixels, 200},
        height: {:pixels, 100},
        constraint: :max
      })

    assert state.errors == []
    assert {Image.width(state.image), Image.height(state.image)} == {100, 50}
  end

  test "cover clamps zero crop dimensions before fitting to image" do
    {:ok, image} = Image.new(20, 20, color: :white)

    state =
      Transform.Cover.execute(%TransformState{image: image}, %Transform.Cover.CoverParams{
        type: :dimensions,
        width: {:pixels, 0},
        height: {:pixels, 10},
        constraint: :none
      })

    assert state.errors == []
    assert {Image.width(state.image), Image.height(state.image)} == {1, 10}
  end

  test "scale proportional downscale returns exact target dimensions" do
    {:ok, image} = Image.new(400, 200, color: :white)

    state =
      Transform.Scale.execute(%TransformState{image: image}, %Transform.Scale.ScaleParams{
        type: :dimensions,
        width: {:pixels, 100},
        height: :auto
      })

    assert state.errors == []
    assert {Image.width(state.image), Image.height(state.image)} == {100, 50}
  end
end
