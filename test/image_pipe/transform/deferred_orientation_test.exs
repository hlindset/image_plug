defmodule ImagePipe.Transform.DeferredOrientationTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Transform.{Materializer, PlanExecutor, State}

  defp marked(w, h),
    do: Image.Draw.rect!(Image.new!(w, h, color: :white), 0, 0, 4, 4, color: :red)

  defp run(plan, image) do
    {:ok, %State{} = s} = PlanExecutor.execute(plan, %State{image: image}, seed_orientation: true)
    # Delivery backstop flush (mirrors processor's materialize_before_delivery).
    {:ok, %State{} = s} = Materializer.materialize(s)
    s.image
  end

  # Orientation-only reference uses the SAME primitives the flush uses.
  defp orientation_only_reference(image, user_rotate, user_flips) do
    {:ok, {img, _}} = Image.autorotate(image)
    img = if user_rotate != 0, do: Image.rotate!(img, user_rotate), else: img
    Enum.reduce(user_flips, img, fn axis, acc -> Image.flip!(acc, axis) end)
  end

  defp sample_positions(size) do
    last = max(size - 1, 0)
    Enum.uniq([0, div(last, 2), last])
  end

  defp assert_pixels_match(a, b) do
    assert {Image.width(a), Image.height(a)} == {Image.width(b), Image.height(b)}

    for x <- sample_positions(Image.width(a)), y <- sample_positions(Image.height(a)) do
      assert Image.get_pixel!(a, x, y) == Image.get_pixel!(b, x, y), "mismatch at (#{x},#{y})"
    end
  end

  defp plan(ops, auto_rotate?) do
    %Plan{
      source: nil,
      output: nil,
      auto_rotate: auto_rotate?,
      pipelines: [%ImagePipe.Plan.Pipeline{operations: ops}]
    }
  end

  defp build_ops(user_rotate, flips) do
    rotate_op = if user_rotate != 0, do: elem(Operation.rotate(user_rotate), 1)
    flip_ops = Enum.map(flips, &elem(Operation.flip(&1), 1))

    Enum.reject([rotate_op | flip_ops], &is_nil/1)
  end

  test "no-geometry EXIF 1..8 + user rotate/flip: deferred flush matches same-primitive reference" do
    for orientation <- 1..8,
        user_rotate <- [0, 90, 180, 270],
        flips <- [[], [:horizontal], [:vertical]] do
      base = Image.set_orientation!(marked(40, 20), orientation)
      ops = build_ops(user_rotate, flips)
      out = run(plan(ops, true), base)
      assert_pixels_match(out, orientation_only_reference(base, user_rotate, flips))
    end
  end
end
