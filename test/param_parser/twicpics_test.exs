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

  defp random_base_unit,
    do:
      one_of([
        tuple({constant(:int), integer(0..9999)}),
        tuple({constant(:float), float(min: 0, max: 9999)})
      ])

  defp random_root_unit,
    do:
      one_of([
        tuple({constant(:int), integer(0..9999)}),
        tuple({constant(:float), float(min: 0, max: 9999)}),
        tuple({constant(:scale), random_base_unit(), random_base_unit()}),
        tuple({constant(:pct), random_base_unit()})
      ])

  defp unit_str({:int, v}), do: "#{v}"
  defp unit_str({:float, v}), do: "#{v}"
  defp unit_str({:scale, unit_a, unit_b}), do: "(#{unit_str(unit_a)}/#{unit_str(unit_b)})s"
  defp unit_str({:pct, unit}), do: "#{unit_str(unit)}p"

  test "crop params parser" do
    check all width <- random_root_unit(),
              height <- random_root_unit(),
              crop_from <-
                one_of([
                  constant(:focus),
                  fixed_map(%{
                    left: random_root_unit(),
                    top: random_root_unit()
                  })
                ]) do
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

  test "focus params parser" do
    check all left <- random_root_unit(),
              top <- random_root_unit() do
      str_params = "#{unit_str(left)}x#{unit_str(top)}"
      parsed = Twicpics.FocusParser.parse(str_params)
      assert {:ok, %Focus.FocusParams{left: left, top: top}} == parsed
    end
  end

  test "scale params parser" do
    check all {width, height, auto} <-
                one_of([
                  tuple({random_root_unit(), random_root_unit(), constant(:none)}),
                  tuple({constant(:auto), random_root_unit(), constant(:width)}),
                  tuple({random_root_unit(), constant(:auto), constant(:height)}),
                  tuple({random_root_unit(), constant(:auto), constant(:simple)})
                ]) do
      str_params =
        case auto do
          :simple -> "#{unit_str(width)}"
          :height -> "#{unit_str(width)}x-"
          :width -> "-x#{unit_str(height)}"
          :none -> "#{unit_str(width)}x#{unit_str(height)}"
        end

      parsed = Twicpics.ScaleParser.parse(str_params)

      assert {:ok, %Scale.ScaleParams{width: width, height: height}} == parsed
    end
  end
end
