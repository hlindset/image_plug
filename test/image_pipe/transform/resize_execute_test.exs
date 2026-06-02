defmodule ImagePipe.Transform.ResizeExecuteTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.State

  test "execute sizes the target from source_dimensions, not the shrunk image" do
    # A 3000x2000 source shrunk 8x on load is 375x250; source_dimensions holds the
    # exact original so the fit target is computed against {3000, 2000}.
    {:ok, shrunk_image} = Image.new(375, 250, color: [128, 128, 128])

    state = %State{image: shrunk_image, source_dimensions: {3000, 2000}}

    # Fit 300x200 of a 3000x2000 source (ratio 1.5, matches) -> 300x200 exactly.
    operation = %Resize{mode: :fit, width: {:pixels, 300}, height: {:pixels, 200}}
    {:ok, new_state} = Resize.execute(operation, state)

    assert Image.width(new_state.image) == 300
    assert Image.height(new_state.image) == 200
    # The residual resize has finished the downscale: source_dimensions clears.
    assert new_state.source_dimensions == nil
  end

  test "execute with no shrink (source_dimensions nil) resizes straight from the image dims" do
    {:ok, image} = Image.new(375, 250, color: [128, 128, 128])
    state = %State{image: image, source_dimensions: nil}

    operation = %Resize{mode: :fit, width: {:pixels, 300}, height: {:pixels, 200}}
    {:ok, new_state} = Resize.execute(operation, state)

    assert Image.width(new_state.image) == 300
    assert Image.height(new_state.image) == 200
    assert new_state.source_dimensions == nil
  end
end
