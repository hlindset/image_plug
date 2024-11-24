defmodule Imagex.CropTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

    # parsed = Crop.Parameters.parse("100x200")
    # assert {:ok, %Crop.Parameters{width: {:int, 100}, height: {:int, 200}, crop_from: :focus}} == parsed

    # parsed = Crop.Parameters.parse("50px20p")
    # assert {:ok, %Crop.Parameters{width: {:pct, 50}, height: {:pct, 20}, crop_from: :focus}} == parsed

    # parsed = Crop.Parameters.parse("50px20")
    # assert {:ok, %Crop.Parameters{width: {:pct, 50}, height: {:int, 20}, crop_from: :focus}} == parsed

    # parsed = Crop.Parameters.parse("50x20p")
    # assert {:ok, %Crop.Parameters{width: {:int, 50}, height: {:pct, 20}, crop_from: :focus}} == parsed

    # parsed = Crop.Parameters.parse("40.53px20.333p")
    # assert {:ok, %Crop.Parameters{width: {:pct, 40.53}, height: {:pct, 20.333}, crop_from: :focus}} == parsed

    # parsed = Crop.Parameters.parse("40x20.333p")
    # assert {:ok, %Crop.Parameters{width: {:int, 40}, height: {:pct, 20.333}, crop_from: :focus}} == parsed

    # parsed = Crop.Parameters.parse("40.53px20")
    # assert {:ok, %Crop.Parameters{width: {:pct, 40.53}, height: {:int, 20}, crop_from: :focus}} == parsed
  end
end
