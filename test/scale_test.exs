defmodule ScaleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest PlugImage.Transform.Scale.Parameters

  alias PlugImage.Transform.Scale

  test "crop parameters parser" do
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
          :height -> "#{format_value.(width)}x*"
          :width -> "*x#{format_value.(height)}"
          :none -> "#{format_value.(width)}x#{format_value.(height)}"
        end

      parsed = Scale.Parameters.parse(str_params)

      assert {:ok, %Scale.Parameters{width: width, height: height}} == parsed
    end
  end
end
