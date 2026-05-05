defmodule ImagePlug.TransformChainTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Transform
  alias ImagePlug.Transform.Contain
  alias ImagePlug.Transform.Scale
  alias ImagePlug.TransformChain
  alias ImagePlug.TransformState

  doctest ImagePlug.TransformChain

  defmodule FailingTransform do
    defstruct []

    def new(attrs), do: {:ok, new!(attrs)}
    def new!(%__MODULE__{} = operation), do: operation
    def new!(attrs), do: struct!(__MODULE__, attrs)

    def name(%__MODULE__{}), do: :failing

    def metadata(%__MODULE__{}), do: %{access: :random}

    def execute(%__MODULE__{}, state) do
      TransformState.add_error(state, {__MODULE__, :failed})
    end
  end

  defmodule UnexpectedTransform do
    defstruct []

    def new(attrs), do: {:ok, new!(attrs)}
    def new!(%__MODULE__{} = operation), do: operation
    def new!(attrs), do: struct!(__MODULE__, attrs)

    def name(%__MODULE__{}), do: :unexpected

    def metadata(%__MODULE__{}), do: %{access: :random}

    def execute(%__MODULE__{}, state) do
      TransformState.add_error(state, {__MODULE__, :should_not_run})
    end
  end

  defmodule PartialTransform do
    defstruct []

    def new(attrs), do: {:ok, new!(attrs)}
    def new!(%__MODULE__{} = operation), do: operation
    def new!(attrs), do: struct!(__MODULE__, attrs)
    def name(%__MODULE__{}), do: :partial
    def execute(%__MODULE__{}, state), do: state
  end

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
      Transform.execute(operation, %TransformState{image: image})
    end
  end

  test "stops executing after the first transform error" do
    {:ok, image} = Image.new(20, 20, color: :white)

    chain = [
      %FailingTransform{},
      %UnexpectedTransform{}
    ]

    assert {:error, {:transform_error, state}} =
             TransformChain.execute(%TransformState{image: image}, chain)

    assert state.errors == [{FailingTransform, :failed}]
  end
end
