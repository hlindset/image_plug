defmodule ImagePipe.Transform.AutoOrientMaterializeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.AutoOrient
  alias ImagePipe.Transform.State

  defp oriented_state(orientation) do
    {:ok, image} = Image.new(40, 20, color: :red)
    image = Image.set_orientation!(image, orientation)
    %State{image: image, materialized?: false}
  end

  test "quarter-turn EXIF (6) materializes and swaps dimensions" do
    {:ok, %State{} = result} = AutoOrient.execute(%AutoOrient{}, oriented_state(6))

    assert result.materialized? == true
    # orientation 6 is a 90-degree turn: 40x20 displays as 20x40
    assert Image.width(result.image) == 20
    assert Image.height(result.image) == 40
  end

  test "row-reversing EXIF (3, 180) materializes without axis swap" do
    {:ok, %State{} = result} = AutoOrient.execute(%AutoOrient{}, oriented_state(3))

    assert result.materialized? == true
    assert Image.width(result.image) == 40
    assert Image.height(result.image) == 20
  end

  test "identity EXIF (1) streams without materializing" do
    {:ok, %State{} = result} = AutoOrient.execute(%AutoOrient{}, oriented_state(1))

    assert result.materialized? == false
  end
end
