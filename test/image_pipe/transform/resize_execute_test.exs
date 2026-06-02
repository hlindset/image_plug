defmodule ImagePipe.Transform.ResizeExecuteTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.State
  alias ImagePipe.Transform.Operation.Resize

  test "execute uses source_dimensions when set, not shrunk image dims" do
    # Simulate a 3000x2000 image shrunk to 375x250 (8x), source_dimensions = {3000, 2000}
    {:ok, shrunk_image} = Image.new(375, 250, color: [128, 128, 128])

    state = %State{
      image: shrunk_image,
      source_dimensions: {3000, 2000}
    }

    # Fit resize target 300x200: computed from {3000,2000}, ratio=1.5 exactly
    operation = %Resize{mode: :fit, width: {:pixels, 300}, height: {:pixels, 200}}
    {:ok, new_state} = Resize.execute(operation, state)

    assert Image.width(new_state.image) == 300
    assert Image.height(new_state.image) == 200
    assert new_state.source_dimensions == nil
  end

  test "execute falls back to image dims when source_dimensions is nil" do
    {:ok, image} = Image.new(375, 250, color: [128, 128, 128])
    state = %State{image: image, source_dimensions: nil}

    operation = %Resize{mode: :fit, width: {:pixels, 300}, height: {:pixels, 200}}
    {:ok, new_state} = Resize.execute(operation, state)

    assert Image.width(new_state.image) == 300
    assert Image.height(new_state.image) == 200
    assert new_state.source_dimensions == nil
  end
end
