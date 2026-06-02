defmodule ImagePipe.Transform.RequiresMaterializationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Blur
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Flip
  alias ImagePipe.Transform.Operation.Rotate

  test "default-classified ops do not require materialization" do
    refute Transform.requires_materialization?(%Background{color: [0, 0, 0, 255]})
    refute Transform.requires_materialization?(%Blur{sigma: 1.0})
  end

  test "rotate requires materialization" do
    assert Transform.requires_materialization?(%Rotate{angle: 90})
    assert Transform.requires_materialization?(%Rotate{angle: 180})
    assert Transform.requires_materialization?(%Rotate{angle: 270})
  end

  test "vertical and both flips require materialization; horizontal does not" do
    assert Transform.requires_materialization?(%Flip{axis: :vertical})
    assert Transform.requires_materialization?(%Flip{axis: :both})
    refute Transform.requires_materialization?(%Flip{axis: :horizontal})
  end

  test "smart/detect crop requires materialization; anchor/focal does not" do
    assert Transform.requires_materialization?(%Crop{width: {:pixels, 10}, height: {:pixels, 10}, gravity: :smart})
    assert Transform.requires_materialization?(%Crop{width: {:pixels, 10}, height: {:pixels, 10}, gravity: {:smart, :face_assist}})
    assert Transform.requires_materialization?(%Crop{width: {:pixels, 10}, height: {:pixels, 10}, gravity: {:detect, {:all, %{}}}})
    refute Transform.requires_materialization?(%Crop{width: {:pixels, 10}, height: {:pixels, 10}, gravity: {:anchor, :center, :center}})
  end
end
