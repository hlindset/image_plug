defmodule ImagePlug.TransformChainTest do
  use ExUnit.Case, async: true

  doctest ImagePlug.TransformChain

  defmodule FailingTransform do
    defstruct []

    def execute(state, %__MODULE__{}) do
      ImagePlug.TransformState.add_error(state, {__MODULE__, :failed})
    end
  end

  defmodule UnexpectedTransform do
    defstruct []

    def execute(state, %__MODULE__{}) do
      ImagePlug.TransformState.add_error(state, {__MODULE__, :should_not_run})
    end
  end

  test "stops executing after the first transform error" do
    {:ok, image} = Image.new(20, 20, color: :white)

    chain = [
      {FailingTransform, %FailingTransform{}},
      {UnexpectedTransform, %UnexpectedTransform{}}
    ]

    assert {:error, {:transform_error, state}} =
             ImagePlug.TransformChain.execute(%ImagePlug.TransformState{image: image}, chain)

    assert state.errors == [{FailingTransform, :failed}]
  end
end
