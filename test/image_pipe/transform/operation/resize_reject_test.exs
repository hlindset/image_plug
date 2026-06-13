defmodule ImagePipe.Transform.Operation.ResizeRejectTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.State

  # 100x100 source
  defp state do
    {:ok, image} = Image.new(100, 100, color: [10, 20, 30])
    %State{image: image}
  end

  test ":reject errors when the requested box exceeds the source" do
    op = %Resize{
      mode: :force,
      width: {:pixels, 200},
      height: {:pixels, 200},
      reject_enlargement: true
    }

    assert {:error, {:bad_request, :upscale_required}} = Resize.execute(op, state())
  end

  test ":reject passes through when the target fits within the source" do
    op = %Resize{
      mode: :fit,
      width: {:pixels, 50},
      height: {:pixels, 50},
      reject_enlargement: true
    }

    assert {:ok, %State{image: out}} = Resize.execute(op, state())
    assert Image.width(out) == 50
  end

  test ":deny (default) clamps an oversized request without erroring" do
    op = %Resize{mode: :fit, width: {:pixels, 200}, height: {:pixels, 200}}
    assert {:ok, %State{image: out}} = Resize.execute(op, state())
    assert Image.width(out) == 100
  end

  test ":reject also fires when a min dimension forces upscaling past the source" do
    op = %Resize{
      mode: :fit,
      width: {:pixels, 50},
      height: {:pixels, 50},
      min_width: {:pixels, 200},
      reject_enlargement: true
    }

    assert {:error, {:bad_request, :upscale_required}} = Resize.execute(op, state())
  end
end
