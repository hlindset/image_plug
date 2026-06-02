defmodule ImagePipe.Transform.ResizeExecuteTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.State

  test "execute computes the target from the prescaled (original) extent, not the shrunk image" do
    # A 3000x2000 source shrunk 8x on load is 375x250; decode_prescale = 1/8.
    # effective_source_dims must recover {3000, 2000} so the fit target is exact.
    {:ok, shrunk_image} = Image.new(375, 250, color: [128, 128, 128])

    state = %State{image: shrunk_image, decode_prescale: 1.0 / 8.0}

    # Fit 300x200 of a 3000x2000 source (ratio 1.5, matches) -> 300x200 exactly.
    operation = %Resize{mode: :fit, width: {:pixels, 300}, height: {:pixels, 200}}
    {:ok, new_state} = Resize.execute(operation, state)

    assert Image.width(new_state.image) == 300
    assert Image.height(new_state.image) == 200
    # The residual resize has finished the downscale: prescale resets to 1.0.
    assert new_state.decode_prescale == 1.0
  end

  test "execute with no shrink (prescale 1.0) resizes straight from the image dims" do
    {:ok, image} = Image.new(375, 250, color: [128, 128, 128])
    state = %State{image: image, decode_prescale: 1.0}

    operation = %Resize{mode: :fit, width: {:pixels, 300}, height: {:pixels, 200}}
    {:ok, new_state} = Resize.execute(operation, state)

    assert Image.width(new_state.image) == 300
    assert Image.height(new_state.image) == 200
    assert new_state.decode_prescale == 1.0
  end
end
