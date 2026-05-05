defmodule ImagePlug.Transform.ChainTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Transform
  alias ImagePlug.Transform.Chain
  alias ImagePlug.Transform.ChainTest.FailingTransform
  alias ImagePlug.Transform.ChainTest.PartialTransform
  alias ImagePlug.Transform.ChainTest.UnexpectedTransform
  alias ImagePlug.Transform.AdaptiveResize
  alias ImagePlug.Transform.Contain
  alias ImagePlug.Transform.Cover
  alias ImagePlug.Transform.Crop
  alias ImagePlug.Transform.ExtendCanvas
  alias ImagePlug.Transform.Focus
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Resize
  alias ImagePlug.Transform.Scale
  alias ImagePlug.Transform.State

  doctest ImagePlug.Transform.Chain

  test "transform modules construct operation structs" do
    assert %Scale{
             type: :dimensions,
             width: {:pixels, 10},
             height: :auto
           } =
             Scale.new!(
               type: :dimensions,
               width: {:pixels, 10},
               height: :auto
             )

    assert %Resize{rule: %DimensionRule{mode: :fit}} =
             Resize.new!(rule: %DimensionRule{mode: :fit, width: {:pixels, 10}})
  end

  test "transform modules support fallible construction" do
    assert {:ok, %Scale{}} =
             Scale.new(
               type: :dimensions,
               width: {:pixels, 10},
               height: :auto
             )

    assert {:ok, %AdaptiveResize{}} =
             AdaptiveResize.new(
               rule: %DimensionRule{mode: :auto, width: {:pixels, 10}, height: {:pixels, 20}}
             )
  end

  test "fallible construction returns errors for missing required attrs" do
    assert {:error, _reason} = Scale.new(type: :dimensions)
  end

  test "scale construction validates malformed attributes" do
    assert {:error,
            %ArgumentError{
              message: "invalid scale dimensions: width and height cannot both be :auto"
            }} =
             Scale.new(type: :dimensions, width: :auto, height: :auto)

    assert {:error, %ArgumentError{message: "invalid scale width: :oops"}} =
             Scale.new(
               type: :dimensions,
               width: :oops,
               height: {:pixels, 100}
             )

    assert {:error, %ArgumentError{message: "invalid scale ratio: {1, 0}"}} =
             Scale.new(type: :ratio, ratio: {1, 0})

    assert {:error, %ArgumentError{message: "unknown scale option(s): :extra"}} =
             Scale.new(
               type: :dimensions,
               width: {:pixels, 100},
               height: :auto,
               extra: true
             )
  end

  test "contain construction validates malformed attributes" do
    assert {:error, %ArgumentError{message: "invalid contain ratio: {1, 0}"}} =
             Contain.new(type: :ratio, ratio: {1, 0}, letterbox: false)

    assert {:error, %ArgumentError{message: "invalid contain width: :oops"}} =
             Contain.new(
               type: :dimensions,
               width: :oops,
               height: {:pixels, 100},
               constraint: :regular,
               letterbox: false
             )

    assert {:error, %ArgumentError{message: "unknown contain option(s): :extra"}} =
             Contain.new(
               type: :dimensions,
               width: {:pixels, 100},
               height: :auto,
               constraint: :regular,
               letterbox: false,
               extra: true
             )
  end

  test "cover construction validates malformed attributes" do
    assert {:error, %ArgumentError{message: "invalid cover ratio: {4, 0}"}} =
             Cover.new(type: :ratio, ratio: {4, 0})

    assert {:error, %ArgumentError{message: "invalid cover height: 0"}} =
             Cover.new(
               type: :dimensions,
               width: {:pixels, 100},
               height: 0,
               constraint: :none
             )

    assert {:error, %ArgumentError{message: "unknown cover option(s): :extra"}} =
             Cover.new(
               type: :dimensions,
               width: {:pixels, 100},
               height: :auto,
               constraint: :none,
               extra: true
             )
  end

  test "crop construction validates malformed attributes" do
    assert {:error, %ArgumentError{message: "invalid crop width: nil"}} =
             Crop.new(width: nil, height: {:pixels, 100}, crop_from: :focus)

    assert {:error, %ArgumentError{message: "invalid crop crop_from_left: :oops"}} =
             Crop.new(
               width: {:pixels, 100},
               height: {:pixels, 100},
               crop_from: %{left: :oops, top: {:pixels, 0}}
             )

    assert {:error, %ArgumentError{message: "unknown crop option(s): :extra"}} =
             Crop.new(
               width: {:pixels, 100},
               height: {:pixels, 100},
               crop_from: :focus,
               extra: true
             )
  end

  test "focus construction validates malformed attributes" do
    assert {:error, %ArgumentError{message: "invalid focus left: :oops"}} =
             Focus.new(type: {:coordinate, :oops, {:percent, 50}})

    assert {:error, %ArgumentError{message: "invalid focus top: nil"}} =
             Focus.new(type: {:coordinate, {:percent, 50}, nil})

    assert {:error, %ArgumentError{message: "unknown focus option(s): :extra"}} =
             Focus.new(type: {:anchor, :left, :top}, extra: true)
  end

  test "neutral resize construction validates malformed attributes" do
    assert {:error, %ArgumentError{message: "invalid resize rule: :oops"}} =
             Resize.new(rule: :oops)

    assert {:error, %ArgumentError{message: "invalid adaptive resize rule: :oops"}} =
             AdaptiveResize.new(rule: :oops)

    assert {:error, %ArgumentError{message: "invalid resize rule mode: :auto"}} =
             Resize.new(rule: %DimensionRule{mode: :auto})

    assert {:error, %ArgumentError{message: "invalid resize rule width: nil"}} =
             Resize.new(rule: %DimensionRule{width: nil})

    assert {:error, %ArgumentError{message: "invalid resize rule height: nil"}} =
             Resize.new(rule: %DimensionRule{height: nil})

    assert {:error, %ArgumentError{message: "invalid resize rule width: :oops"}} =
             Resize.new(rule: %DimensionRule{width: :oops})

    assert {:error, %ArgumentError{message: "invalid resize rule zoom_x: nil"}} =
             Resize.new(rule: %DimensionRule{zoom_x: nil})

    assert {:error, %ArgumentError{message: "invalid resize rule zoom_y: nil"}} =
             Resize.new(rule: %DimensionRule{zoom_y: nil})

    assert {:error, %ArgumentError{message: "invalid resize rule dpr: nil"}} =
             Resize.new(rule: %DimensionRule{dpr: nil})

    assert {:error, %ArgumentError{message: "invalid resize rule dpr: nil"}} =
             Resize.new(%Resize{rule: %DimensionRule{dpr: nil}})

    assert {:error, %ArgumentError{message: "invalid resize rule dpr: 0"}} =
             Resize.new(rule: %DimensionRule{dpr: 0})

    assert {:error, %ArgumentError{message: "invalid resize rule enlarge: nil"}} =
             Resize.new(rule: %DimensionRule{enlarge: nil})

    assert {:error, %ArgumentError{message: "invalid adaptive resize rule mode: :fill"}} =
             AdaptiveResize.new(rule: %DimensionRule{mode: :fill})

    assert {:error, %ArgumentError{message: "invalid adaptive resize rule width: nil"}} =
             AdaptiveResize.new(rule: %DimensionRule{mode: :auto, width: nil})

    assert {:error, %ArgumentError{message: "invalid adaptive resize rule width: nil"}} =
             AdaptiveResize.new(%AdaptiveResize{rule: %DimensionRule{mode: :auto, width: nil}})

    assert {:error, %ArgumentError{message: "invalid adaptive resize rule height: nil"}} =
             AdaptiveResize.new(rule: %DimensionRule{mode: :auto, height: nil})

    assert {:error, %ArgumentError{message: "invalid adaptive resize rule zoom_x: nil"}} =
             AdaptiveResize.new(rule: %DimensionRule{mode: :auto, zoom_x: nil})

    assert {:error, %ArgumentError{message: "invalid adaptive resize rule zoom_y: nil"}} =
             AdaptiveResize.new(rule: %DimensionRule{mode: :auto, zoom_y: nil})

    assert {:error, %ArgumentError{message: "invalid adaptive resize rule dpr: nil"}} =
             AdaptiveResize.new(rule: %DimensionRule{mode: :auto, dpr: nil})

    assert {:error, %ArgumentError{message: "invalid adaptive resize rule enlarge: :oops"}} =
             AdaptiveResize.new(rule: %DimensionRule{mode: :auto, enlarge: :oops})

    assert {:error, %ArgumentError{message: "invalid adaptive resize rule enlarge: nil"}} =
             AdaptiveResize.new(rule: %DimensionRule{mode: :auto, enlarge: nil})

    assert {:error, %ArgumentError{message: "invalid extend canvas rule: :oops"}} =
             ExtendCanvas.new(rule: :oops)

    assert {:error, %ArgumentError{message: "unknown resize option(s): :extra"}} =
             Resize.new(rule: %DimensionRule{}, extra: true)
  end

  test "transform name is delegated to operation module" do
    operation =
      Scale.new!(
        type: :dimensions,
        width: {:pixels, 10},
        height: :auto
      )

    assert Transform.transform_name(operation) == :scale
  end

  test "metadata is delegated to operation module" do
    operation =
      Contain.new!(
        type: :dimensions,
        width: {:pixels, 10},
        height: :auto,
        constraint: :regular,
        letterbox: false
      )

    assert Transform.metadata(operation) == %{access: :sequential}
  end

  test "partial operation structs fail strict dispatch" do
    operation = %PartialTransform{}

    refute Transform.operation?(operation)

    assert_raise ArgumentError, fn ->
      Transform.transform_name(operation)
    end

    assert_raise ArgumentError, fn ->
      Transform.metadata(operation)
    end

    {:ok, image} = Image.new(20, 20, color: :white)

    assert_raise ArgumentError, fn ->
      Transform.execute(operation, %State{image: image})
    end
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

  test "scale execution records an error for direct auto/auto structs" do
    {:ok, image} = Image.new(20, 20, color: :white)

    chain = [
      %Scale{type: :dimensions, width: :auto, height: :auto}
    ]

    assert {:error, {:transform_error, state}} =
             Chain.execute(%State{image: image}, chain)

    assert state.errors == [
             {Scale, {:error, {:invalid_scale_dimensions, :auto_auto}}}
           ]
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
      %Resize{rule: %DimensionRule{mode: :fill, width: {:pixels, 100}, height: {:pixels, 100}}}
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 100
  end

  test "adaptive resize chooses cover behavior for matching orientation" do
    {:ok, image} = Image.new(200, 100, color: :white)

    chain = [
      %AdaptiveResize{
        rule: %DimensionRule{mode: :auto, width: {:pixels, 100}, height: {:pixels, 50}}
      }
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 50
  end
end
