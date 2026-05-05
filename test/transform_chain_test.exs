defmodule ImagePlug.Transform.ChainTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Transform
  alias ImagePlug.Transform.Chain
  alias ImagePlug.Transform.ChainTest.FailingTransform
  alias ImagePlug.Transform.ChainTest.PartialTransform
  alias ImagePlug.Transform.ChainTest.UnexpectedTransform
  alias ImagePlug.Transform.Contain
  alias ImagePlug.Transform.Cover
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
  end

  test "transform modules support fallible construction" do
    assert {:ok, %Scale{}} =
             Scale.new(
               type: :dimensions,
               width: {:pixels, 10},
               height: :auto
             )
  end

  test "fallible construction returns errors for missing required attrs" do
    assert {:error, _reason} = Scale.new(type: :dimensions)
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
end
