defmodule ImagePipe.Transform.AutoOrientMaterializeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.AutoOrient
  alias ImagePipe.Transform.State

  # 40x20 white image with a red 4x4 block in the top-left corner.
  # Asymmetric both in dimensions (40w × 20h) and in content (the marker
  # is off-center), so every EXIF orientation maps the marker to a distinct
  # pixel position. A missing or wrong rotation produces different pixel
  # values at sampled positions and fails the reference comparison.
  defp marked_image do
    {:ok, base} = Image.new(40, 20, color: :white)
    Image.Draw.rect!(base, 0, 0, 4, 4, color: :red)
  end

  defp oriented(base, orientation), do: Image.set_orientation!(base, orientation)

  defp oriented_state(base, orientation) do
    %State{image: oriented(base, orientation), materialized?: false}
  end

  defp reference_autorotated(base, orientation) do
    {:ok, {image, _flags}} = Image.autorotate(oriented(base, orientation))
    image
  end

  defp assert_pixels_match(left, right) do
    assert Image.width(left) == Image.width(right)
    assert Image.height(left) == Image.height(right)

    for x <- sample_positions(Image.width(left)),
        y <- sample_positions(Image.height(left)) do
      assert Image.get_pixel!(left, x, y) == Image.get_pixel!(right, x, y),
             "pixel mismatch at (#{x}, #{y})"
    end
  end

  defp sample_positions(size) do
    last = max(size - 1, 0)
    Enum.uniq([0, div(last, 4), div(last, 2), div(last * 3, 4), last])
  end

  for orientation <- 1..8 do
    @orientation orientation
    @expected_materialized orientation not in [1, 2]

    test "orientation #{orientation}: materialized?=#{orientation not in [1, 2]}, output matches Image.autorotate reference" do
      base = marked_image()
      state = oriented_state(base, @orientation)

      {:ok, %State{} = result} = AutoOrient.execute(%AutoOrient{}, state)

      assert result.materialized? == @expected_materialized

      reference = reference_autorotated(base, @orientation)
      assert_pixels_match(result.image, reference)
    end
  end
end
