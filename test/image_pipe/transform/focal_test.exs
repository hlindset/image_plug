defmodule ImagePipe.Transform.FocalTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Focal

  # Scene in a 100×100 image: a tall "person" box and a small "face" box high
  # inside it, sharing center x = 50. Vertical centroid is the discriminating axis.
  defp scene do
    [
      %{label: "person", score: 0.9, box: {30, 20, 40, 70}},
      %{label: "face", score: 0.9, box: {40, 20, 20, 20}}
    ]
  end

  test "uniform area-weighted centroid (empty weights)" do
    assert {:ok, {:fp, fx, fy}} = Focal.weighted_centroid(scene(), 100, 100, %{})
    assert_in_delta fx, 0.5, 0.0001
    # area: (2800·55 + 400·30) / 3200 = 51.875
    assert_in_delta fy, 0.51875, 0.0001
  end

  test "a uniform default scalar does not move the centroid (cancels)" do
    {:ok, fp_a} = Focal.weighted_centroid(scene(), 100, 100, %{})
    {:ok, fp_b} = Focal.weighted_centroid(scene(), 100, 100, %{default: 2.0})
    assert fp_a == fp_b
  end

  test "returns :none when no box falls fully inside the image" do
    assert Focal.weighted_centroid([%{label: "x", box: {200, 200, 10, 10}}], 100, 100, %{}) ==
             :none
  end

  test "a missing label resolves to the default/1.0 weight" do
    regions = [%{box: {0, 0, 10, 10}}, %{box: {90, 90, 10, 10}}]
    assert {:ok, {:fp, fx, fy}} = Focal.weighted_centroid(regions, 100, 100, %{})
    assert_in_delta fx, 0.5, 0.0001
    assert_in_delta fy, 0.5, 0.0001
  end
end
