defmodule ImagePipe.Transform.DecodePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.AutoOrient
  alias ImagePipe.Transform.DecodePlanner

  test "empty chains open randomly with fail_on error" do
    assert DecodePlanner.open_options([]) == [access: :random, fail_on: :error]
  end

  test "width-only fit resize opens sequentially" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 120}, :auto)

    assert DecodePlanner.open_options([resize]) == [access: :sequential, fail_on: :error]
  end

  test "height-only fit resize opens sequentially" do
    assert {:ok, resize} = Operation.resize(:fit, :auto, {:px, 120})

    assert DecodePlanner.open_options([resize]) == [access: :sequential, fail_on: :error]
  end

  test "auto-orient-only chains open sequentially" do
    assert DecodePlanner.open_options([
             %AutoOrient{}
           ]) == [access: :sequential, fail_on: :error]
  end

  test "two-dimensional fit resize opens sequentially" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 120}, {:px, 90})

    assert DecodePlanner.open_options([resize]) == [access: :sequential, fail_on: :error]
  end

  test "stretch resize with requested dimensions opens sequentially" do
    assert {:ok, width_only} = Operation.resize(:stretch, {:px, 120}, :auto)

    assert DecodePlanner.open_options([width_only]) == [access: :sequential, fail_on: :error]

    assert {:ok, dimensions} = Operation.resize(:stretch, {:px, 120}, {:px, 90})

    assert DecodePlanner.open_options([dimensions]) == [access: :sequential, fail_on: :error]
  end

  test "crops stay random" do
    assert {:ok, crop} = Operation.crop_guided({:px, 80}, {:px, 80}, :center)

    assert DecodePlanner.open_options([crop]) == [access: :random, fail_on: :error]
  end

  test "unresolved semantic source-dependent operations stay random before metadata" do
    assert {:ok, resize_auto} = Operation.resize(:auto, {:px, 80}, {:px, 80})

    assert {:ok, crop_region} =
             Operation.crop_region(
               {:ratio, 1, 4},
               {:ratio, 1, 4},
               {:ratio, 1, 2},
               {:ratio, 1, 2}
             )

    assert DecodePlanner.open_options([resize_auto]) == [access: :random, fail_on: :error]
    assert DecodePlanner.open_options([crop_region]) == [access: :random, fail_on: :error]
  end

  test "composition operations force random access" do
    assert {:ok, padding} = Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 0})
    assert {:ok, red} = Operation.color(255, 0, 0)
    assert {:ok, background} = Operation.background(red)

    assert DecodePlanner.open_options([padding]) == [access: :random, fail_on: :error]
    assert DecodePlanner.open_options([background]) == [access: :random, fail_on: :error]
  end

  test "effect operations force random access" do
    assert {:ok, blur} = Operation.blur(2.0)
    assert {:ok, sharpen} = Operation.sharpen(0.7)
    assert {:ok, pixelate} = Operation.pixelate(8)
    assert {:ok, brightness} = Operation.brightness(20)
    assert {:ok, contrast} = Operation.contrast(-15)
    assert {:ok, saturation} = Operation.saturation(35)

    assert DecodePlanner.open_options([blur]) == [access: :random, fail_on: :error]
    assert DecodePlanner.open_options([sharpen]) == [access: :random, fail_on: :error]
    assert DecodePlanner.open_options([pixelate]) == [access: :random, fail_on: :error]
    assert DecodePlanner.open_options([brightness]) == [access: :random, fail_on: :error]
    assert DecodePlanner.open_options([contrast]) == [access: :random, fail_on: :error]
    assert DecodePlanner.open_options([saturation]) == [access: :random, fail_on: :error]
  end

  test "planned options include only access and fail_on" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 120}, :auto)

    assert Keyword.keys(DecodePlanner.open_options([resize])) == [:access, :fail_on]
  end
end
