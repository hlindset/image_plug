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

  test "whole-valued floats canonicalize to integers (50p and 50.0p share a key)" do
    {:ok, int_op} = Operation.resize(:fit, {:percent, 50}, {:scale, 2})
    {:ok, float_op} = Operation.resize(:fit, {:percent, 50.0}, {:scale, 2.0})

    assert KeyData.data(int_op) == KeyData.data(float_op)
    assert KeyData.data(int_op)[:width] == [unit: :percent, value: 50]

    # Genuinely fractional values keep their float form.
    {:ok, frac_op} = Operation.resize(:fit, {:percent, 50.5}, :auto)
    assert KeyData.data(frac_op)[:width] == [unit: :percent, value: 50.5]
  end

  test "distinct relative magnitudes produce distinct key data" do
    {:ok, op50} = Operation.resize(:fit, {:percent, 50}, :auto)
    {:ok, op60} = Operation.resize(:fit, {:percent, 60}, :auto)

    refute KeyData.data(op50) == KeyData.data(op60)
  end
end
