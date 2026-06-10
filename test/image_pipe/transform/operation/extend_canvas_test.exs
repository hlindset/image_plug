defmodule ImagePipe.Transform.Operation.ExtendCanvasTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

  defp white(width, height) do
    {:ok, black} = Operation.black(width, height, bands: 3)
    {:ok, img} = Operation.linear(black, [1.0, 1.0, 1.0], [255.0, 255.0, 255.0])
    {:ok, img} = Operation.cast(img, :VIPS_FORMAT_UCHAR)
    img
  end

  defp state(image), do: %State{image: image} |> Map.put(:materialized?, true)

  # Top-left of the opaque white content inside a transparent-black-padded canvas:
  # the smallest (x, y) whose red band == 255 (content) rather than 0 (pad).
  defp content_origin(image) do
    {:ok, bin} = VixImage.write_to_binary(image)
    width = Image.width(image)
    height = Image.height(image)
    bands = Image.bands(image)
    stride = width * bands

    content =
      for y <- 0..(height - 1),
          x <- 0..(width - 1),
          :binary.at(bin, y * stride + x * bands) == 255,
          do: {x, y}

    {content |> Enum.map(&elem(&1, 0)) |> Enum.min(),
     content |> Enum.map(&elem(&1, 1)) |> Enum.min()}
  end

  # #195/#196 regression: centered embed must match imgproxy calc_position.go
  # (`ShrinkToEven(outer - inner + 1, 2)`), not a floor of `(outer - inner) / 2`.
  # For an inner 4x4 in an 11x10 canvas the imgproxy origin is (4, 4); a plain floor
  # would place it at (3, 3) — the 1px slip that drove the extend divergences.
  test "center gravity places the inner image at the imgproxy origin" do
    op = %ExtendCanvas{
      rule: {:dimensions, {:pixels, 11}, {:pixels, 10}},
      gravity: {:anchor, :center, :center},
      background: :transparent
    }

    assert {:ok, %State{image: out}} = ExtendCanvas.execute(op, state(white(4, 4)))
    assert {Image.width(out), Image.height(out)} == {11, 10}
    assert content_origin(out) == {4, 4}
  end

  test "left/top gravity pins the inner image to the origin" do
    op = %ExtendCanvas{
      rule: {:dimensions, {:pixels, 11}, {:pixels, 10}},
      gravity: {:anchor, :left, :top},
      background: :transparent
    }

    assert {:ok, %State{image: out}} = ExtendCanvas.execute(op, state(white(4, 4)))
    assert content_origin(out) == {0, 0}
  end

  test "right/bottom gravity pins the inner image to the far edge" do
    op = %ExtendCanvas{
      rule: {:dimensions, {:pixels, 11}, {:pixels, 10}},
      gravity: {:anchor, :right, :bottom},
      background: :transparent
    }

    assert {:ok, %State{image: out}} = ExtendCanvas.execute(op, state(white(4, 4)))
    # inner 4x4 flush to the far edge of an 11x10 canvas: (11-4, 10-4)
    assert content_origin(out) == {7, 6}
  end
end
