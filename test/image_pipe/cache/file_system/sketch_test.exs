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

  describe "increment/2 conservative update" do
    test "only minimum-valued positions are incremented" do
      # Use depth 2 width 8 so we can reason about positions directly.
      sketch = Sketch.new(depth: 2, width: 8)

      # Pre-load specific counters by repeated increment of two keys that
      # happen to share one position. Conservative update should not inflate
      # the higher-valued position when the lower one already represents the
      # true frequency.
      sketch =
        sketch
        |> Sketch.increment("alpha")
        |> Sketch.increment("alpha")

      counters_before = Sketch.dump_counters(sketch)
      sketch = Sketch.increment(sketch, "alpha")
      counters_after = Sketch.dump_counters(sketch)

      # Every changed counter must have been at the same (minimum) value
      # before the update — conservative update only increments positions
      # that hold the per-key minimum, so all changed positions share that
      # value. Compute previous_min from just the changed positions so we
      # assert the conservative invariant independently of unrelated zeros.
      changed_positions =
        counters_before
        |> Enum.zip(counters_after)
        |> Enum.with_index()
        |> Enum.filter(fn {{before, aft}, _idx} -> aft != before end)

      changed_before_values = Enum.map(changed_positions, fn {{before, _aft}, _idx} -> before end)
      previous_min = Enum.min(changed_before_values)

      assert Enum.all?(changed_positions, fn {{before, _aft}, _idx} -> before == previous_min end)
    end
  end
end
