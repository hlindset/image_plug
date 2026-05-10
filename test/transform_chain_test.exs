defmodule ImagePlug.Transform.ChainTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Transform
  alias ImagePlug.Transform.Chain
  alias ImagePlug.Transform.ChainTest.FailingTransform
  alias ImagePlug.Transform.ChainTest.UnexpectedTransform
  alias ImagePlug.Transform.Operation.Contain
  alias ImagePlug.Transform.Operation.Cover
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.ExtendCanvas
  alias ImagePlug.Transform.Operation.Focus
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.Operation.Scale
  alias ImagePlug.Transform.State

  doctest ImagePlug.Transform.Chain

  test "transform modules expose valid operation structs" do
    assert :ok =
             Transform.validate(%Scale{
               type: :dimensions,
               width: {:pixels, 10},
               height: :auto
             })

    assert :ok =
             Transform.validate(%Resize{
               rule: %DimensionRule{mode: :fit, width: {:pixels, 10}}
             })
  end

  test "transform validation rejects malformed operation structs" do
    assert {:error, %ArgumentError{}} =
             Transform.validate(%Scale{
               type: :dimensions,
               width: :oops,
               height: {:pixels, 100}
             })

    assert {:error, %ArgumentError{}} =
             Transform.validate(%Contain{type: :ratio, ratio: {1, 0}, letterbox: false})

    assert {:error, %ArgumentError{}} =
             Transform.validate(%Cover{
               type: :dimensions,
               width: {:pixels, 100},
               height: 0,
               constraint: :none
             })

    assert {:error, %ArgumentError{}} =
             Transform.validate(%Crop{width: nil, height: {:pixels, 100}, crop_from: :focus})

    assert {:error, %ArgumentError{}} =
             Transform.validate(%Focus{type: {:coordinate, :oops, {:percent, 50}}})

    assert {:error, %ArgumentError{}} =
             Transform.validate(%Resize{rule: %DimensionRule{mode: :auto}})

    assert {:error, %ArgumentError{}} =
             Transform.validate(%ExtendCanvas{rule: :oops})
  end

  test "transform name is delegated to operation module" do
    operation = %Scale{
      type: :dimensions,
      width: {:pixels, 10},
      height: :auto
    }

    assert Transform.transform_name(operation) == :scale
  end

  test "metadata is delegated to operation module" do
    operation = %Contain{
      type: :dimensions,
      width: {:pixels, 10},
      height: :auto,
      constraint: :regular,
      letterbox: false
    }

    assert Transform.metadata(operation) == %{access: :sequential}
  end

  test "zero-dimension resize rules stay random access" do
    operation = %Resize{
      rule: %DimensionRule{mode: :fit, width: {:pixels, 0}, height: :auto}
    }

    assert Transform.metadata(operation) == %{access: :random}
  end

  test "stops executing after the first transform error" do
    {:ok, image} = Image.new(20, 20, color: :white)

    chain = [
      %FailingTransform{},
      %UnexpectedTransform{}
    ]

    assert {:error, {:transform_error, state}} =
             Chain.execute(%State{image: image}, chain)

    assert state.errors == [{FailingTransform, :failed}]
  end

  test "neutral resize and canvas operations execute through the chain" do
    {:ok, image} = Image.new(200, 100, color: :white)

    chain = [
      %Resize{rule: %DimensionRule{mode: :fit, width: {:pixels, 100}, height: {:pixels, 100}}},
      %ExtendCanvas{rule: {:dimensions, {:pixels, 100}, {:pixels, 100}}}
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 100
  end

  test "fill resize crops non-square sources to the requested box" do
    {:ok, image} = Image.new(200, 100, color: :white)

    chain = [
      %Resize{rule: %DimensionRule{mode: :fill, width: {:pixels, 100}, height: {:pixels, 100}}},
      %Crop{
        width: :auto,
        height: :auto,
        crop_from: :gravity,
        gravity: {:anchor, :center, :center},
        target_rule: %DimensionRule{mode: :fill, width: {:pixels, 100}, height: {:pixels, 100}}
      }
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 100
  end

  test "fill result crop applies non-center gravity after resize" do
    image =
      300
      |> Image.new!(100, color: :black)
      |> Image.Draw.rect!(0, 0, 100, 100, color: :red)
      |> Image.Draw.rect!(100, 0, 100, 100, color: :green)
      |> Image.Draw.rect!(200, 0, 100, 100, color: :blue)

    chain = [
      %Resize{rule: %DimensionRule{mode: :fill, width: {:pixels, 100}, height: {:pixels, 100}}},
      %Crop{
        width: :auto,
        height: :auto,
        crop_from: :gravity,
        gravity: {:anchor, :right, :center},
        target_rule: %DimensionRule{mode: :fill, width: {:pixels, 100}, height: {:pixels, 100}}
      }
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 100
    assert Image.get_pixel!(image, 50, 50) == [0, 0, 255]
  end

  test "fill resize crops to min-adjusted target dimensions" do
    for mode <- [:fill, :fill_down] do
      {:ok, image} = Image.new(1000, 500, color: :white)

      chain = [
        %Resize{
          rule: %DimensionRule{
            mode: mode,
            width: {:pixels, 100},
            height: {:pixels, 100},
            min_width: {:pixels, 300}
          }
        },
        %Crop{
          width: :auto,
          height: :auto,
          crop_from: :gravity,
          gravity: {:anchor, :center, :center},
          target_rule: %DimensionRule{
            mode: mode,
            width: {:pixels, 100},
            height: {:pixels, 100},
            min_width: {:pixels, 300}
          }
        }
      ]

      assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
      assert Image.width(image) == 300
      assert Image.height(image) == 300
    end
  end

  test "zero-dimension resize with zoom clamps raster sources when enlarge is false" do
    {:ok, image} = Image.new(100, 50, color: :white)

    chain = [
      %Resize{
        rule: %DimensionRule{
          mode: :fit,
          width: {:pixels, 0},
          height: {:pixels, 0},
          zoom_x: 2.0,
          zoom_y: 1.5
        }
      }
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 38
  end

  test "zero-dimension resize with dpr preserves raster sources when enlarge is false" do
    {:ok, image} = Image.new(100, 50, color: :white)

    chain = [
      %Resize{
        rule: %DimensionRule{
          mode: :fit,
          width: {:pixels, 0},
          height: {:pixels, 0},
          dpr: 2.0
        }
      }
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 50
  end

  test "fill-down crops clamped images to the requested aspect ratio" do
    {:ok, image} = Image.new(200, 100, color: :white)

    chain = [
      %Resize{
        rule: %DimensionRule{
          mode: :fill_down,
          width: {:pixels, 300},
          height: {:pixels, 300},
          enlarge: true
        }
      },
      %Crop{
        width: :auto,
        height: :auto,
        crop_from: :gravity,
        gravity: {:anchor, :center, :center},
        target_rule: %DimensionRule{
          mode: :fill_down,
          width: {:pixels, 300},
          height: {:pixels, 300},
          enlarge: true
        }
      }
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 100
  end

  test "extend canvas raises for invalid unvalidated runtime dimensions" do
    {:ok, image} = Image.new(100, 100, color: :white)

    chain = [
      %ExtendCanvas{
        rule: {:dimensions, {:scale, 1, 0}, {:pixels, 100}}
      }
    ]

    assert_raise ArgumentError, fn ->
      Chain.execute(%State{image: image}, chain)
    end
  end
end
