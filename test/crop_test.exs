defmodule CropTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  doctest Imagex.Transform.Crop.Parameters

  alias Imagex.Transform.Crop

  test "crop parameters parser" do
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

      parsed = Crop.Parameters.parse(str_params)

      assert {:ok,
              %Crop.Parameters{
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
end
