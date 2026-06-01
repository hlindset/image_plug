defmodule ImagePipe.Plan.KeyDataTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.KeyData
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Resize

  test "encodes percent and scale resize dimensions" do
    {:ok, %Resize{} = op} = Operation.resize(:fit, {:percent, 50}, {:scale, 0.5})
    data = KeyData.data(op)

    assert data[:width] == [unit: :percent, value: 50]
    assert data[:height] == [unit: :scale, value: 0.5]
  end
end
