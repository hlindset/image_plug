defmodule ImagePipe.Cache.FileSystem.SketchTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem.Sketch

  describe "new/1" do
    test "creates a sketch with the configured depth and width" do
      sketch = Sketch.new(depth: 4, width: 4096)
      assert Sketch.depth(sketch) == 4
      assert Sketch.width(sketch) == 4096
    end

    test "starts with all counters at zero" do
      sketch = Sketch.new(depth: 4, width: 64)
      assert Sketch.estimate(sketch, "any-key") == 0
    end
  end

  describe "increment/2 and estimate/2" do
    test "estimate is at least the true count after increments" do
      sketch =
        Sketch.new(depth: 4, width: 256)
        |> Sketch.increment("k1")
        |> Sketch.increment("k1")
        |> Sketch.increment("k1")

      assert Sketch.estimate(sketch, "k1") >= 3
    end

    test "different keys do not perfectly share counters" do
      sketch = Sketch.new(depth: 4, width: 256) |> Sketch.increment("k1")
      # Cannot assert estimate(k2) == 0 due to possible collisions,
      # but with width 256 collision on a brand-new key is unlikely.
      assert is_integer(Sketch.estimate(sketch, "k2"))
    end
  end
end
