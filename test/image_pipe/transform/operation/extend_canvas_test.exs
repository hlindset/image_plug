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

  # #200: imgproxy moves the image AWAY from an anchored right/bottom edge by the
  # offset (`left = outer - inner - offX`, calc_position.go), where ExtendCanvas
  # previously added (toward/past the edge). East anchor, offset 2 on an inner 4
  # in an 11-wide canvas: base 11-4=7, away from east edge → 7-2=5.
  test "east gravity moves the image away from the right edge by the offset (#200)" do
    op = %ExtendCanvas{
      rule: {:dimensions, {:pixels, 11}, {:pixels, 10}},
      gravity: {:anchor, :right, :top},
      x_offset: 2.0,
      background: :transparent
    }

    assert {:ok, %State{image: out}} = ExtendCanvas.execute(op, state(white(4, 4)))
    assert content_origin(out) == {5, 0}
  end

  test "south gravity moves the image away from the bottom edge by the offset (#200)" do
    op = %ExtendCanvas{
      rule: {:dimensions, {:pixels, 11}, {:pixels, 10}},
      gravity: {:anchor, :left, :bottom},
      y_offset: 2.0,
      background: :transparent
    }

    assert {:ok, %State{image: out}} = ExtendCanvas.execute(op, state(white(4, 4)))
    # bottom base 10-4=6, away from south edge → 6-2=4
    assert content_origin(out) == {0, 4}
  end

  # #200: imgproxy clamps the resolved origin to [0, outer - inner] (calcPosition,
  # allowOverflow=false). An east offset larger than the base drives the subtract
  # negative; it must clamp to 0, not place the image off-canvas.
  test "east offset beyond the base clamps the origin to zero (#200)" do
    op = %ExtendCanvas{
      rule: {:dimensions, {:pixels, 11}, {:pixels, 10}},
      gravity: {:anchor, :right, :top},
      x_offset: 10.0,
      background: :transparent
    }

    assert {:ok, %State{image: out}} = ExtendCanvas.execute(op, state(white(4, 4)))
    assert content_origin(out) == {0, 0}
  end

  test "west offset beyond the far edge clamps the origin to outer - inner (#200)" do
    op = %ExtendCanvas{
      rule: {:dimensions, {:pixels, 11}, {:pixels, 10}},
      gravity: {:anchor, :left, :top},
      x_offset: 20.0,
      background: :transparent
    }

    assert {:ok, %State{image: out}} = ExtendCanvas.execute(op, state(white(4, 4)))
    # west base 0, add 20, clamp to outer - inner = 11 - 4 = 7
    assert content_origin(out) == {7, 0}
  end

  # #200 guard: center keeps ADDing the offset (calcPosition center adds offX/offY);
  # only right/bottom anchors flip the sign. Center origin of inner 4 in 11 is 4
  # (ShrinkToEven(11-4+1, 2)); +2 → 6, within [0, 7] so the clamp is a no-op.
  test "center gravity still adds the offset (#200 fallthrough preserved)" do
    op = %ExtendCanvas{
      rule: {:dimensions, {:pixels, 11}, {:pixels, 10}},
      gravity: {:anchor, :center, :center},
      x_offset: 2.0,
      background: :transparent
    }

    assert {:ok, %State{image: out}} = ExtendCanvas.execute(op, state(white(4, 4)))
    assert content_origin(out) == {6, 4}
  end
end
