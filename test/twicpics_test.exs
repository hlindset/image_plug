defmodule TwicpicsTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Transform
  alias ImagePlug.ParamParser.Twicpics

  test "parse from string" do
    result = Twicpics.parse_string("v1/focus=(1/2)sx(2/3)s/crop=100x100/resize=200/output=avif")

    assert result ==
             {:ok,
              [
                {Transform.Focus,
                 %Transform.Focus.FocusParams{
                   left: {:scale, {:int, 1}, {:int, 2}},
                   top: {:scale, {:int, 2}, {:int, 3}}
                 }},
                {Transform.Crop,
                 %Transform.Crop.CropParams{
                   width: {:int, 100},
                   height: {:int, 100},
                   crop_from: :focus
                 }},
                {Transform.Scale,
                 %Transform.Scale.ScaleParams{
                   width: {:int, 200},
                   height: :auto
                 }},
                {Transform.Output,
                 %Transform.Output.OutputParams{
                   format: :avif
                 }}
              ]}
  end
end
