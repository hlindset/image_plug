defmodule ParamParser.TwicpicsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest ImagePlug.ParamParser.Twicpics.CropParser
  doctest ImagePlug.ParamParser.Twicpics.ScaleParser
  doctest ImagePlug.ParamParser.Twicpics.FocusParser

  alias ImagePlug.ParamParser.Twicpics
  alias ImagePlug.Transform.Crop
  alias ImagePlug.Transform.Scale
  alias ImagePlug.Transform.Focus

  test "crop params parser" do
    int_or_pct =
      one_of([
        tuple({constant(:int), integer(0..9999)}),
        tuple({constant(:pct), one_of([integer(0..9999), float(min: 0, max: 9999)])})
      ])

    check all width <- int_or_pct,
              height <- int_or_pct,
              crop_from <-
                one_of([
                  constant(:focus),
                  fixed_map(%{
                    left: int_or_pct,
                    top: int_or_pct
                  })
                ]) do
      format_value = fn
        {:pct, value} -> "#{value}p"
        {:int, value} -> "#{value}"
      end

      str_params = "#{format_value.(width)}x#{format_value.(height)}"

      str_params =
        case crop_from do
          :focus -> str_params
          %{left: left, top: top} -> "#{str_params}@#{format_value.(left)}x#{format_value.(top)}"
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

  test "focus params parser" do
    check all left <- integer(0..9999),
              top <- integer(0..9999) do
      str_params = "#{left}x#{top}"
      parsed = Twicpics.FocusParser.parse(str_params)
      assert {:ok, %Focus.FocusParams{left: left, top: top}} == parsed
    end
  end

  test "scale params parser" do
    int_or_pct =
      one_of([
        tuple({constant(:int), integer(0..9999)}),
        tuple({constant(:pct), one_of([integer(0..9999), float(min: 0, max: 9999)])})
      ])

    check all {width, height, auto} <-
                one_of([
                  tuple({int_or_pct, int_or_pct, constant(:none)}),
                  tuple({constant(:auto), int_or_pct, constant(:width)}),
                  tuple({int_or_pct, constant(:auto), constant(:height)}),
                  tuple({int_or_pct, constant(:auto), constant(:simple)})
                ]) do
      format_value = fn
        {:pct, value} -> "#{value}p"
        {:int, value} -> "#{value}"
      end

      str_params =
        case auto do
          :simple -> "#{format_value.(width)}"
          :height -> "#{format_value.(width)}x-"
          :width -> "-x#{format_value.(height)}"
          :none -> "#{format_value.(width)}x#{format_value.(height)}"
        end

      parsed = Twicpics.ScaleParser.parse(str_params)

      assert {:ok, %Scale.ScaleParams{width: width, height: height}} == parsed
    end
  end
end
