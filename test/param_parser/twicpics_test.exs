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
end
