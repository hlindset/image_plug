defmodule ImagePipe.Transform.Operation.AutoOrientTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.AutoOrient
  alias ImagePipe.Transform.State

  test "swaps stored source_dimensions when a quarter-turn rotation swaps the image axes" do
    # EXIF orientation 6 rotates 90°, so autorotate turns 120x80 into 80x120.
    # When shrink-on-load stored the original extent for the residual resize, that
    # extent must swap in step so it keeps describing the now-rotated image.
    {:ok, image} = Image.new(120, 80, color: [255, 0, 0])
    oriented = Image.set_orientation!(image, 6)

    state = %State{image: oriented, source_dimensions: {3000, 2000}}

    {:ok, new_state} = AutoOrient.execute(%AutoOrient{}, state)

    assert {Image.width(new_state.image), Image.height(new_state.image)} == {80, 120}
    assert new_state.source_dimensions == {2000, 3000}
  end

  test "leaves source_dimensions untouched when the image is not re-oriented" do
    # Orientation 1 (the default) is a no-op rotation: axes unchanged, so the
    # stored original must not be swapped.
    {:ok, image} = Image.new(120, 80, color: [0, 255, 0])

    state = %State{image: image, source_dimensions: {3000, 2000}}

    {:ok, new_state} = AutoOrient.execute(%AutoOrient{}, state)

    assert {Image.width(new_state.image), Image.height(new_state.image)} == {120, 80}
    assert new_state.source_dimensions == {3000, 2000}
  end

  test "is a no-op on source_dimensions when none is stored (no shrink-on-load)" do
    {:ok, image} = Image.new(120, 80, color: [0, 0, 255])
    oriented = Image.set_orientation!(image, 6)

    state = %State{image: oriented, source_dimensions: nil}

    {:ok, new_state} = AutoOrient.execute(%AutoOrient{}, state)

    assert {Image.width(new_state.image), Image.height(new_state.image)} == {80, 120}
    assert new_state.source_dimensions == nil
  end
end
