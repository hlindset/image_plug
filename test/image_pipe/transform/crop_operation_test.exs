defmodule ImagePipe.Transform.CropOperationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.State

  defp state(width, height) do
    {:ok, image} = Image.new(width, height, color: :white)
    %State{image: image}
  end

  defp dimensions(%State{image: image}), do: {Image.width(image), Image.height(image)}

  test "reduce shrinks the long axis to match ratio (default)" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 1, 1},
      enlarge: false
    }

    {:ok, result} = Crop.execute(op, state(400, 400))
    assert {100, 100} == dimensions(result)
  end

  test "enlarge grows the short axis to match ratio" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 1, 1},
      enlarge: true
    }

    {:ok, result} = Crop.execute(op, state(400, 400))
    assert {200, 200} == dimensions(result)
  end

  test "enlarge clamps to image bounds keeping ratio" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 1, 1},
      enlarge: true
    }

    # image only 150 tall; enlarged 200x200 must shrink to fit -> 150x150
    {:ok, result} = Crop.execute(op, state(400, 150))
    assert {150, 150} == dimensions(result)
  end

  test "nil aspect_ratio leaves the crop unchanged" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: nil,
      enlarge: false
    }

    {:ok, result} = Crop.execute(op, state(400, 400))
    assert {100, 200} == dimensions(result)
  end
end
