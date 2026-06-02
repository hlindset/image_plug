defmodule ImagePipe.Transform.RequiresMaterializationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Blur

  test "default-classified ops do not require materialization" do
    refute Transform.requires_materialization?(%Background{color: [0, 0, 0, 255]})
    refute Transform.requires_materialization?(%Blur{sigma: 1.0})
  end
end
