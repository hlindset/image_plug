defmodule ImagePlug.ParamParser.TwicpicsParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ImagePlug.TestSupport

  alias ImagePlug.ParamParser.Twicpics
  alias ImagePlug.Transform.Crop
  alias ImagePlug.Transform.Scale
  alias ImagePlug.Transform.Focus
  alias ImagePlug.Transform.Contain

  doctest ImagePlug.ParamParser.Twicpics.CropParser
  doctest ImagePlug.ParamParser.Twicpics.ScaleParser
  doctest ImagePlug.ParamParser.Twicpics.FocusParser
  doctest ImagePlug.ParamParser.Twicpics.ContainParser
  doctest ImagePlug.ParamParser.Twicpics.OutputParser

  defp unit_str({:int, v}), do: "#{v}"
  defp unit_str({:float, v}), do: "#{v}"
  defp unit_str({:scale, unit_a, unit_b}), do: "(#{unit_str(unit_a)}/#{unit_str(unit_b)})s"
  defp unit_str({:pct, unit}), do: "#{unit_str(unit)}p"

  test "crop params parser" do
    check all width <- random_root_unit(),
              height <- random_root_unit(),
              crop_from <- crop_from() do
      str_params = "#{unit_str(width)}x#{unit_str(height)}"

      str_params =
        case crop_from do
          :focus -> str_params
          %{left: left, top: top} -> "#{str_params}@#{unit_str(left)}x#{unit_str(top)}"
        end

      parsed = Twicpics.CropParser.parse(str_params)

      assert {:ok,
              %Crop.CropParams{
                width: width,
                height: height,
                crop_from:
                  case crop_from do
                    :focus -> :focus
                    %{left: left, top: top} -> %{left: left, top: top}
                  end
              }} ==
               parsed
    end
  end

  def anchor_to_str({:anchor, :center, :top}), do: "top"
  def anchor_to_str({:anchor, :left, :top}), do: "top-left"
  def anchor_to_str({:anchor, :right, :top}), do: "top-right"
  def anchor_to_str({:anchor, :center, :center}), do: "center"
  def anchor_to_str({:anchor, :left, :center}), do: "left"
  def anchor_to_str({:anchor, :right, :center}), do: "right"
  def anchor_to_str({:anchor, :center, :bottom}), do: "bottom"
  def anchor_to_str({:anchor, :left, :bottom}), do: "bottom-left"
  def anchor_to_str({:anchor, :right, :bottom}), do: "bottom-right"

  test "focus params parser" do
    check all focus_type <- focus_type() do
      str_params =
        case focus_type do
          {:coordinate, left, top} -> "#{unit_str(left)}x#{unit_str(top)}"
          {:anchor, _, _} = anchor -> anchor_to_str(anchor)
        end

      {:ok, parsed} = Twicpics.FocusParser.parse(str_params)
      assert %Focus.FocusParams{type: focus_type} == parsed
    end
  end

  test "scale params parser" do
    check all {type, params} <-
                one_of([
                  tuple({constant(:auto_width), tuple({random_root_unit()})}),
                  tuple({constant(:auto_height), tuple({random_root_unit()})}),
                  tuple({constant(:simple), tuple({random_root_unit()})}),
                  tuple(
                    {constant(:width_and_height), tuple({random_root_unit(), random_root_unit()})}
                  ),
                  tuple(
                    {constant(:aspect_ratio), tuple({random_root_unit(), random_root_unit()})}
                  )
                ]) do
      {str_params, expected} =
        case {type, params} do
          {:auto_width, {height}} ->
            {"-x#{unit_str(height)}",
             %Scale.ScaleParams{
               method: %Scale.ScaleParams.Dimensions{width: :auto, height: height}
             }}

          {:auto_height, {width}} ->
            {"#{unit_str(width)}x-",
             %Scale.ScaleParams{
               method: %Scale.ScaleParams.Dimensions{width: width, height: :auto}
             }}

          {:simple, {width}} ->
            {"#{unit_str(width)}",
             %Scale.ScaleParams{
               method: %Scale.ScaleParams.Dimensions{width: width, height: :auto}
             }}

          {:width_and_height, {width, height}} ->
            {"#{unit_str(width)}x#{unit_str(height)}",
             %Scale.ScaleParams{
               method: %Scale.ScaleParams.Dimensions{width: width, height: height}
             }}

          {:aspect_ratio, {ar_w, ar_h}} ->
            {"#{unit_str(ar_w)}:#{unit_str(ar_h)}",
             %Scale.ScaleParams{
               method: %Scale.ScaleParams.AspectRatio{aspect_ratio: {:ratio, ar_w, ar_h}}
             }}
        end

      {:ok, parsed} = Twicpics.ScaleParser.parse(str_params)

      assert parsed == expected
    end
  end

  test "contain params parser" do
    check all width <- random_root_unit(),
              height <- random_root_unit() do
      str_params = "#{unit_str(width)}x#{unit_str(height)}"
      parsed = Twicpics.ContainParser.parse(str_params)
      assert {:ok, %Contain.ContainParams{width: width, height: height}} == parsed
    end
  end
end
