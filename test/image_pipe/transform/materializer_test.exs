defmodule ImagePipe.Transform.MaterializerTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State

  test "materialize/1 returns a memory-resident State with materialized?: true" do
    {:ok, image} = Image.new(32, 24, color: :white)
    state = %State{image: image, materialized?: false}

    assert {:ok, %State{} = result} = Materializer.materialize(state)
    assert result.materialized? == true
    assert Image.width(result.image) == 32
    assert Image.height(result.image) == 24
  end
end
