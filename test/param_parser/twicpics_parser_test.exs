defmodule ImagePlug.ParamParser.TwicpicsParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import ImagePlug.TestSupport

  alias ImagePlug.ParamParser.Twicpics
  alias ImagePlug.Transform.Crop
  alias ImagePlug.Transform.Scale
  alias ImagePlug.Transform.Focus
  alias ImagePlug.Transform.Contain

  doctest ImagePlug.ParamParser.Twicpics.Transform.CropParser
  doctest ImagePlug.ParamParser.Twicpics.Transform.ScaleParser
  doctest ImagePlug.ParamParser.Twicpics.Transform.FocusParser
  doctest ImagePlug.ParamParser.Twicpics.Transform.ContainParser
  doctest ImagePlug.ParamParser.Twicpics.Transform.OutputParser

  defp length_str({:pixels, unit}), do: "#{unit}"
  defp length_str({:scale, unit_a, unit_b}), do: "(#{unit_a}/#{unit_b})s"
  defp length_str({:percent, unit}), do: "#{unit}p"

  defp to_result({:pixels, unit}), do: {:pixels, unit}
  defp to_result({:scale, unit_a, unit_b}), do: {:scale, unit_a / unit_b}
  defp to_result({:percent, unit}), do: {:percent, unit}

  test "crop params parser" do
    check all width <- random_root_unit(min: 1),
              height <- random_root_unit(min: 1),
              crop_from <- crop_from() do
      str_params = "#{length_str(width)}x#{length_str(height)}"

      str_params =
        case crop_from do
          :focus -> str_params
          %{left: left, top: top} -> "#{str_params}@#{length_str(left)}x#{length_str(top)}"
        end

      parsed = Twicpics.Transform.CropParser.parse(str_params)

      assert {:ok,
              %Crop.CropParams{
                width: to_result(width),
                height: to_result(height),
                crop_from:
                  case crop_from do
                    :focus -> :focus
                    %{left: left, top: top} -> %{left: to_result(left), top: to_result(top)}
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
          {:coordinate, left, top} -> "#{length_str(left)}x#{length_str(top)}"
          {:anchor, _, _} = anchor -> anchor_to_str(anchor)
        end

      {:ok, parsed} = Twicpics.Transform.FocusParser.parse(str_params)

      case focus_type do
        {:coordinate, left, top} ->
          assert %Focus.FocusParams{type: {:coordinate, to_result(left), to_result(top)}} ==
                   parsed

        {:anchor, _, _} ->
          assert %Focus.FocusParams{type: focus_type} == parsed
      end
    end
  end

  test "scale params parser" do
    check all {type, params} <-
                one_of([
                  tuple({constant(:auto_width), tuple({random_root_unit(min: 1)})}),
                  tuple({constant(:auto_height), tuple({random_root_unit(min: 1)})}),
                  tuple({constant(:simple), tuple({random_root_unit(min: 1)})}),
                  tuple(
                    {constant(:width_and_height),
                     tuple({random_root_unit(min: 1), random_root_unit(min: 1)})}
                  ),
                  tuple(
                    {constant(:aspect_ratio),
                     tuple({random_base_unit(min: 1), random_base_unit(min: 1)})}
                  )
                ]) do
      {str_params, expected} =
        case {type, params} do
          {:auto_width, {height}} ->
            {"-x#{length_str(height)}",
             %Scale.ScaleParams{
               type: :dimensions,
               width: :auto,
               height: to_result(height)
             }}

          {:auto_height, {width}} ->
            {"#{length_str(width)}x-",
             %Scale.ScaleParams{
               type: :dimensions,
               width: to_result(width),
               height: :auto
             }}

          {:simple, {width}} ->
            {"#{length_str(width)}",
             %Scale.ScaleParams{
               type: :dimensions,
               width: to_result(width),
               height: :auto
             }}

          {:width_and_height, {width, height}} ->
            {"#{length_str(width)}x#{length_str(height)}",
             %Scale.ScaleParams{
               type: :dimensions,
               width: to_result(width),
               height: to_result(height)
             }}

          {:aspect_ratio, {ar_w, ar_h}} ->
            {"#{ar_w}:#{ar_h}", %Scale.ScaleParams{type: :ratio, ratio: {ar_w, ar_h}}}
        end

      {:ok, parsed} = Twicpics.Transform.ScaleParser.parse(str_params)

      assert parsed == expected
    end
  end

  test "contain params parser" do
    check all width <- random_root_unit(min: 1),
              height <- random_root_unit(min: 1) do
      str_params = "#{length_str(width)}x#{length_str(height)}"
      parsed = Twicpics.Transform.ContainParser.parse(str_params)

      assert {:ok,
              %Contain.ContainParams{
                width: to_result(width),
                height: to_result(height),
                constraint: :none
              }} ==
               parsed
    end
  end
end
