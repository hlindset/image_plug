defmodule ImagePlug.TransformExecutableCharacterizationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Transform.Chain
  alias ImagePlug.Transform.Operation.Crop
  alias ImagePlug.Transform.Operation.ExtendCanvas
  alias ImagePlug.Transform.Operation.Resize
  alias ImagePlug.Transform.State

  defp generated_state(width, height) do
    {:ok, image} = Image.new(width, height, color: :white)
    %State{image: image}
  end

  defp execute!(state, operations) do
    assert {:ok, %State{} = state} = Chain.execute(state, operations)
    state
  end

  defp dimensions(%State{image: image}), do: {Image.width(image), Image.height(image)}

  test "existing executable resize modes preserve current dimensions" do
    fit =
      generated_state(300, 200)
      |> execute!([
        %Resize{mode: :fit, width: {:pixels, 100}, height: {:pixels, 100}}
      ])

    fill =
      generated_state(300, 200)
      |> execute!([
        %Resize{mode: :fill, width: {:pixels, 100}, height: {:pixels, 100}},
        %Crop{
          width: {:pixels, 100},
          height: {:pixels, 100},
          crop_from: :gravity,
          gravity: {:anchor, :center, :center},
          x_offset: {:pixels, 0},
          y_offset: {:pixels, 0}
        }
      ])

    force =
      generated_state(300, 200)
      |> execute!([
        %Resize{mode: :force, width: :auto, height: {:pixels, 100}}
      ])

    assert dimensions(fit) == {100, 67}
    assert dimensions(fill) == {100, 100}
    assert dimensions(force) == {300, 100}
  end

  test "canvas extension changes canvas dimensions independently from resize scale" do
    state =
      generated_state(100, 50)
      |> execute!([
        %ExtendCanvas{
          rule: {:dimensions, {:pixels, 120}, {:pixels, 80}},
          gravity: {:anchor, :center, :center},
          x_offset: 0.0,
          y_offset: 0.0,
          background: :white
        }
      ])

    assert dimensions(state) == {120, 80}
  end

  test "current cover output requires fill resize plus result crop" do
    resize_only =
      generated_state(300, 200)
      |> execute!([
        %Resize{mode: :fill, width: {:pixels, 100}, height: {:pixels, 50}}
      ])

    resize_then_crop =
      generated_state(300, 200)
      |> execute!([
        %Resize{mode: :fill, width: {:pixels, 100}, height: {:pixels, 50}},
        %Crop{
          width: {:pixels, 100},
          height: {:pixels, 50},
          crop_from: :gravity,
          gravity: {:anchor, :center, :center}
        }
      ])

    assert dimensions(resize_only) == {100, 67}
    assert dimensions(resize_then_crop) == {100, 50}
  end

  test "executable background supports alpha-capable composition" do
    {:ok, image} = Image.new(2, 2, color: [0, 0, 0, 0])
    state = %State{image: image}

    state =
      execute!(state, [
        %ImagePlug.Transform.Operation.Background{color: [255, 0, 0, 128]}
      ])

    assert Image.get_pixel!(state.image, 0, 0) == [255, 0, 0, 128]
  end
end
