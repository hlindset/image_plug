defmodule ImagePlug.Cache.MaterialTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Cache.Material
  alias ImagePlug.Transform

  test "contain params emit canonical material" do
    assert Material.material(%Transform.Contain.ContainParams{
             type: :dimensions,
             width: {:pixels, 300},
             height: :auto,
             constraint: :max,
             letterbox: false
           }) == [
             op: :contain,
             type: :dimensions,
             width: {:pixels, 300},
             height: :auto,
             constraint: :max,
             letterbox: false
           ]
  end

  test "cover params emit canonical material" do
    assert Material.material(%Transform.Cover.CoverParams{
             type: :dimensions,
             width: {:pixels, 300},
             height: {:pixels, 200},
             constraint: :none
           }) == [
             op: :cover,
             type: :dimensions,
             width: {:pixels, 300},
             height: {:pixels, 200},
             constraint: :none
           ]
  end

  test "crop params emit canonical material" do
    assert Material.material(%Transform.Crop.CropParams{
             width: {:pixels, 200},
             height: {:pixels, 100},
             crop_from: :focus
           }) == [
             op: :crop,
             width: {:pixels, 200},
             height: {:pixels, 100},
             crop_from: :focus
           ]
  end

  test "focus params emit canonical material" do
    assert Material.material(%Transform.Focus.FocusParams{
             type: {:coordinate, {:percent, 25.0}, {:percent, 75.0}}
           }) == [
             op: :focus,
             type: {:coordinate, {:percent, 25.0}, {:percent, 75.0}}
           ]
  end

  test "scale params emit canonical material" do
    assert Material.material(%Transform.Scale.ScaleParams{
             type: :dimensions,
             width: {:pixels, 300},
             height: :auto
           }) == [
             op: :scale,
             type: :dimensions,
             width: {:pixels, 300},
             height: :auto
           ]
  end

  test "output params are not cache material" do
    params =
      :erlang.binary_to_term(
        :erlang.term_to_binary(%Transform.Output.OutputParams{format: :webp})
      )

    assert_raise Protocol.UndefinedError, fn ->
      Material.material(params)
    end
  end
end
