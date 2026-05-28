# Bounded Filesystem Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an optional bounded mode to `ImagePipe.Cache.FileSystem` with cost-aware W-TinyLFU admission, a Bloom doorkeeper, a soft `:max_size_bytes` cap, and persisted CMS state for warm-start across restarts (including multi-node warm-start by reading peer state files at boot).

**Architecture:** A single `Admission` GenServer per cache root owns in-memory CMS + doorkeeper + W-TinyLFU queues (window + probationary + protected). The existing pure-callback `FileSystem` adapter gains a `child_spec/1` that starts the GenServer when `:max_size_bytes` is configured, lazily looks up the process via `Registry` at request time, calls `admit/1` synchronously before rename in `commit_sink`, and `cast`s hit-increments on `get/2`. Unbounded behavior (no `:max_size_bytes`) is unchanged.

**Tech Stack:** Elixir, ExUnit, StreamData (property tests), NimbleOptions (config), `:ets`, `:erlang.term_to_binary/2`, `:erlang.phash2/2`, existing `ImagePipe.Telemetry` helpers, `Registry`.

**Spec:** [docs/superpowers/specs/2026-05-28-bounded-filesystem-cache-design.md](../specs/2026-05-28-bounded-filesystem-cache-design.md)

---

## File Structure

**New `lib/` files (all under `ImagePipe.Cache.FileSystem.*` namespace):**

| Path | Responsibility |
|---|---|
| `lib/image_pipe/cache/file_system/sketch.ex` | Pure-data Count-Min Sketch: increment (conservative update), estimate (min over rows), aging (halving + epoch), serialization round-trip, element-wise sum (for `boot_cms` merge). |
| `lib/image_pipe/cache/file_system/policy.ex` | Pure functions: `score/1`, `weighted_avg_score/1`, `victim_walk/3`, `admit?/2`. No state. |
| `lib/image_pipe/cache/file_system/admission.ex` | `GenServer` owning `local_cms`, `doorkeeper` (`Talan.BloomFilter`), `boot_cms`, three ETS queue tables, byte accounting. Synchronous `admit/1`, async `hit/1`. Runs aging, flush ticker, cleanup ticker, boot warm-start, and background directory scan. |

**Modified `lib/` files:**

| Path | Change |
|---|---|
| `lib/image_pipe/cache/entry/metadata.ex` | Add `cost_us` field. |
| `lib/image_pipe/cache/file_system.ex` | Add bounded-mode `child_spec/1`; persist `cost_us` and `body_byte_size` to meta payload; read them back on `get/2`; thread admission decision into `commit_sink`; delete victim files on `{:admit, victims}`; cast hit on successful `get/2`; lazy `Registry.lookup/2` at request time. |
| `lib/image_pipe/cache/sink.ex` | Thread `cost_us` (sum of stage durations) into `Entry.Metadata` at commit time. |
| `lib/image_pipe/cache.ex` | Export `FileSystem` boundary extensions if needed (likely none — `FileSystem.*` modules are non-exported internals). |

**New `test/` files:**

| Path | Coverage |
|---|---|
| `test/image_pipe/cache/file_system/sketch_test.exs` | Sketch construction, increment, conservative update, estimate, aging, serialization. |
| `test/image_pipe/cache/file_system/sketch_property_test.exs` | `estimate(k) >= true_count(k)`; aging preserves relative ordering. |
| `test/image_pipe/cache/file_system/policy_test.exs` | Score arithmetic (float, cost_us=0 fallback); main-gate decisions; victim walks across probationary and into protected; weighted-average rule. |
| `test/image_pipe/cache/file_system/admission_test.exs` | GenServer: boot from various state files, admit window+main flow, hits, aging trigger, flush dirty flag, cleanup ticker, scan race resolution, same-key replace, restart-via-supervisor warm-starts state. |
| `test/image_pipe/cache/file_system_bounded_test.exs` | Adapter end-to-end with bounded config: 1.5× cap cycle, eviction file deletion, admission-rejection telemetry, cross-node warm-start. |
| `test/image_pipe/cache/file_system_bounded_property_test.exs` | Soft-cap invariant property: after any random admission sequence, `Admission`-tracked bytes never exceed cap by more than the sum of in-flight admitted descriptors. |

**Modified `test/` files:**

| Path | Change |
|---|---|
| `test/image_pipe/architecture_boundary_test.exs` | Add namespace assertions for `ImagePipe.Cache.FileSystem.*`. |
| `test/image_pipe/cache/file_system_test.exs` | No changes — existing tests continue to verify unbounded mode unchanged. |

**Doc files:**

| Path | Change |
|---|---|
| `docs/cache.md` | Add bounded-mode configuration section, `:node_id` stability requirement, supervision-tree ordering note, telemetry additions. |

---

## Phase 1: Pure modules (Sketch, Policy) + doorkeeper dependency

These have no GenServer dependencies, are independently testable, and constitute the algorithmic core.

### Task 1: Sketch — construction and basic increment

**Files:**
- Create: `lib/image_pipe/cache/file_system/sketch.ex`
- Create: `test/image_pipe/cache/file_system/sketch_test.exs`

- [ ] **Step 1: Write failing tests for construction and basic increment**

```elixir
# test/image_pipe/cache/file_system/sketch_test.exs
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
```

- [ ] **Step 2: Run the test, confirm failure**

```bash
mise exec -- mix test test/image_pipe/cache/file_system/sketch_test.exs
```
Expected: failure — `ImagePipe.Cache.FileSystem.Sketch` undefined.

- [ ] **Step 3: Implement minimal Sketch with non-conservative increment**

```elixir
# lib/image_pipe/cache/file_system/sketch.ex
defmodule ImagePipe.Cache.FileSystem.Sketch do
  @moduledoc false

  @enforce_keys [:depth, :width, :sample_size, :counters, :aging_epoch, :increments_since_reset]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          depth: pos_integer(),
          width: pos_integer(),
          sample_size: pos_integer(),
          counters: :array.array(non_neg_integer()),
          aging_epoch: non_neg_integer(),
          increments_since_reset: non_neg_integer()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    depth = Keyword.fetch!(opts, :depth)
    width = Keyword.fetch!(opts, :width)

    # `sample_size` is the number of CMS increments between aging passes.
    # It is DELIBERATELY decoupled from `width`: width is sized for counter
    # accuracy (collision rate), while the aging cadence tracks how many
    # distinct accesses constitute a sampling window — a cardinality
    # concept, not an accuracy one. The `width * 10` value here is only a
    # convenience default so pure-Sketch unit tests need not specify it;
    # production always passes an explicit `:sample_size` computed by the
    # config layer (`:aging_sample_size`, Task 25) from estimated cache
    # cardinality, so tuning `:sketch_width` for accuracy never silently
    # changes how fast frequencies decay.
    sample_size = Keyword.get(opts, :sample_size, width * 10)

    %__MODULE__{
      depth: depth,
      width: width,
      sample_size: sample_size,
      counters: :array.new(depth * width, default: 0, fixed: true),
      aging_epoch: 0,
      increments_since_reset: 0
    }
  end

  @spec depth(t()) :: pos_integer()
  def depth(%__MODULE__{depth: d}), do: d

  @spec width(t()) :: pos_integer()
  def width(%__MODULE__{width: w}), do: w

  @spec increment(t(), binary()) :: t()
  def increment(%__MODULE__{} = sketch, key) when is_binary(key) do
    positions = positions_for(sketch, key)

    new_counters =
      Enum.reduce(positions, sketch.counters, fn pos, counters ->
        :array.set(pos, min(255, :array.get(pos, counters) + 1), counters)
      end)

    %{sketch | counters: new_counters, increments_since_reset: sketch.increments_since_reset + 1}
  end

  @spec estimate(t(), binary()) :: non_neg_integer()
  def estimate(%__MODULE__{} = sketch, key) when is_binary(key) do
    sketch
    |> positions_for(key)
    |> Enum.map(&:array.get(&1, sketch.counters))
    |> Enum.min()
  end

  defp positions_for(%__MODULE__{depth: depth, width: width}, key) do
    for row <- 0..(depth - 1) do
      hash = :erlang.phash2({row, key}, width)
      row * width + hash
    end
  end
end
```

- [ ] **Step 4: Run tests, confirm pass**

```bash
mise exec -- mix test test/image_pipe/cache/file_system/sketch_test.exs
```
Expected: 4 passed.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/sketch.ex test/image_pipe/cache/file_system/sketch_test.exs
git commit -m "Add Sketch module with basic Count-Min Sketch operations"
```

---

### Task 2: Sketch — conservative update

**Files:**
- Modify: `lib/image_pipe/cache/file_system/sketch.ex`
- Modify: `test/image_pipe/cache/file_system/sketch_test.exs`

- [ ] **Step 1: Add failing test for conservative update behavior**

Append to `test/image_pipe/cache/file_system/sketch_test.exs`:

```elixir
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

      # Every changed counter must have been at the previous min value.
      previous_min = Enum.min(counters_before)
      changed_positions =
        counters_before
        |> Enum.zip(counters_after)
        |> Enum.with_index()
        |> Enum.filter(fn {{before, aft}, _idx} -> aft != before end)

      assert Enum.all?(changed_positions, fn {{before, _aft}, _idx} -> before == previous_min end)
    end
  end
```

- [ ] **Step 2: Run test, confirm failure**

```bash
mise exec -- mix test test/image_pipe/cache/file_system/sketch_test.exs
```
Expected: failure — `dump_counters/1` undefined, or behavior incorrect.

- [ ] **Step 3: Implement conservative update + dump helper**

Replace the body of `increment/2` and add `dump_counters/1`:

```elixir
  @spec increment(t(), binary()) :: t()
  def increment(%__MODULE__{} = sketch, key) when is_binary(key) do
    positions = positions_for(sketch, key)
    current_values = Enum.map(positions, &:array.get(&1, sketch.counters))
    min_value = Enum.min(current_values)

    new_counters =
      positions
      |> Enum.zip(current_values)
      |> Enum.reduce(sketch.counters, fn {pos, value}, counters ->
        if value == min_value and value < 255 do
          :array.set(pos, value + 1, counters)
        else
          counters
        end
      end)

    %{sketch | counters: new_counters, increments_since_reset: sketch.increments_since_reset + 1}
  end

  @doc false
  @spec dump_counters(t()) :: [non_neg_integer()]
  def dump_counters(%__MODULE__{counters: counters}), do: :array.to_list(counters)
```

- [ ] **Step 4: Run tests, confirm pass**

```bash
mise exec -- mix test test/image_pipe/cache/file_system/sketch_test.exs
```
Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/sketch.ex test/image_pipe/cache/file_system/sketch_test.exs
git commit -m "Use conservative-update increment in Sketch"
```

---

### Task 3: Sketch — aging

**Files:**
- Modify: `lib/image_pipe/cache/file_system/sketch.ex`
- Modify: `test/image_pipe/cache/file_system/sketch_test.exs`

- [ ] **Step 1: Add failing tests for aging behavior**

Append to test file:

```elixir
  describe "age/1" do
    test "halves all counters with (c + 1) >>> 1" do
      sketch = Sketch.new(depth: 2, width: 4)
      sketch = Enum.reduce(1..10, sketch, fn _, s -> Sketch.increment(s, "k") end)

      before = Sketch.dump_counters(sketch)
      sketch = Sketch.age(sketch)
      after_ = Sketch.dump_counters(sketch)

      assert Enum.zip(before, after_) |> Enum.all?(fn {b, a} -> a == Bitwise.bsr(b + 1, 1) end)
    end

    test "increments aging epoch and resets increments_since_reset" do
      sketch = Sketch.new(depth: 2, width: 4)
      sketch = Sketch.increment(sketch, "k") |> Sketch.age()
      assert sketch.aging_epoch == 1
      assert sketch.increments_since_reset == 0
    end
  end

  describe "should_age?/1" do
    test "returns true when increments_since_reset >= sample_size" do
      # sample_size is explicit and independent of width.
      sketch = Sketch.new(depth: 2, width: 4, sample_size: 40)
      threshold = 40

      sketch =
        Enum.reduce(1..(threshold - 1), sketch, fn _, s -> Sketch.increment(s, "k") end)

      refute Sketch.should_age?(sketch)

      sketch = Sketch.increment(sketch, "k")
      assert Sketch.should_age?(sketch)
    end

    test "aging cadence does not change when width changes (decoupled)" do
      # Same sample_size, different width → identical aging threshold.
      narrow = Sketch.new(depth: 2, width: 4, sample_size: 40)
      wide = Sketch.new(depth: 2, width: 4096, sample_size: 40)
      assert narrow.sample_size == wide.sample_size
    end
  end
```

- [ ] **Step 2: Run tests, confirm failure**

- [ ] **Step 3: Implement aging**

Add `Bitwise` import and the two functions:

```elixir
  import Bitwise

  @spec age(t()) :: t()
  def age(%__MODULE__{} = sketch) do
    new_counters = :array.map(fn _idx, value -> bsr(value + 1, 1) end, sketch.counters)

    %{
      sketch
      | counters: new_counters,
        aging_epoch: sketch.aging_epoch + 1,
        increments_since_reset: 0
    }
  end

  @spec should_age?(t()) :: boolean()
  def should_age?(%__MODULE__{sample_size: s, increments_since_reset: n}), do: n >= s
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/sketch.ex test/image_pipe/cache/file_system/sketch_test.exs
git commit -m "Add Sketch aging with halving and epoch tracking"
```

---

### Task 4: Sketch — serialization and element-wise sum

**Files:**
- Modify: `lib/image_pipe/cache/file_system/sketch.ex`
- Modify: `test/image_pipe/cache/file_system/sketch_test.exs`

- [ ] **Step 1: Add failing tests for serialize/deserialize and sum**

```elixir
  describe "serialize/1 and deserialize/1" do
    test "round-trips a sketch preserving counters, epoch, and state" do
      sketch = Sketch.new(depth: 2, width: 4)
      sketch = Enum.reduce(["a", "b", "a", "c"], sketch, &Sketch.increment(&2, &1))

      binary = Sketch.serialize(sketch)
      {:ok, restored} = Sketch.deserialize(binary, depth: 2, width: 4)

      assert Sketch.dump_counters(restored) == Sketch.dump_counters(sketch)
      assert restored.aging_epoch == sketch.aging_epoch
      assert restored.increments_since_reset == sketch.increments_since_reset
    end

    test "returns error on garbage input" do
      assert {:error, _} = Sketch.deserialize(<<0, 1, 2>>, depth: 2, width: 4)
    end

    test "returns error on shape mismatch" do
      sketch = Sketch.new(depth: 2, width: 4)
      binary = Sketch.serialize(sketch)
      assert {:error, _} = Sketch.deserialize(binary, depth: 4, width: 4)
    end
  end

  describe "sum/2" do
    test "element-wise adds counters from two sketches of equal shape" do
      a = Sketch.new(depth: 2, width: 4) |> Sketch.increment("k1") |> Sketch.increment("k1")
      b = Sketch.new(depth: 2, width: 4) |> Sketch.increment("k1") |> Sketch.increment("k2")

      summed = Sketch.sum(a, b)

      # estimate(k1) on summed must be >= estimate(k1) on a + estimate(k1) on b
      assert Sketch.estimate(summed, "k1") >= Sketch.estimate(a, "k1") + Sketch.estimate(b, "k1") - 4
    end
  end
```

- [ ] **Step 2: Run tests, confirm failure**

- [ ] **Step 3: Implement serialize/deserialize/sum**

```elixir
  @serialization_version 1

  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = sketch) do
    :erlang.term_to_binary(
      %{
        version: @serialization_version,
        depth: sketch.depth,
        width: sketch.width,
        counters: :array.to_list(sketch.counters),
        aging_epoch: sketch.aging_epoch,
        increments_since_reset: sketch.increments_since_reset
      },
      [:deterministic]
    )
  end

  @spec deserialize(binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def deserialize(binary, opts) when is_binary(binary) do
    expected_depth = Keyword.fetch!(opts, :depth)
    expected_width = Keyword.fetch!(opts, :width)
    # sample_size is config-derived, not persisted (it is not part of the
    # serialized payload). Reconstruct it from the current config so a
    # restart with a re-tuned `:aging_sample_size` takes effect immediately.
    sample_size = Keyword.get(opts, :sample_size, expected_width * 10)

    try do
      case :erlang.binary_to_term(binary, [:safe]) do
        %{
          version: @serialization_version,
          depth: ^expected_depth,
          width: ^expected_width,
          counters: counters,
          aging_epoch: epoch,
          increments_since_reset: increments
        }
        when is_list(counters) and length(counters) == expected_depth * expected_width and
               is_integer(epoch) and is_integer(increments) ->
          counters_array = :array.from_list(counters, 0)

          {:ok,
           %__MODULE__{
             depth: expected_depth,
             width: expected_width,
             sample_size: sample_size,
             counters: counters_array,
             aging_epoch: epoch,
             increments_since_reset: increments
           }}

        _other ->
          {:error, :invalid_shape}
      end
    rescue
      ArgumentError -> {:error, :decode_failed}
    end
  end

  @spec sum(t(), t()) :: t()
  def sum(%__MODULE__{depth: d, width: w} = a, %__MODULE__{depth: d, width: w} = b) do
    new_counters =
      :array.map(
        fn idx, value -> min(255, value + :array.get(idx, b.counters)) end,
        a.counters
      )

    %__MODULE__{
      depth: d,
      width: w,
      # Aging cadence belongs to the live sketch; carry `a`'s sample_size.
      sample_size: a.sample_size,
      counters: new_counters,
      aging_epoch: max(a.aging_epoch, b.aging_epoch),
      increments_since_reset: 0
    }
  end
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/sketch.ex test/image_pipe/cache/file_system/sketch_test.exs
git commit -m "Add Sketch serialization and element-wise sum"
```

---

### Task 5: Sketch property tests

**Files:**
- Create: `test/image_pipe/cache/file_system/sketch_property_test.exs`

- [ ] **Step 1: Write property tests**

```elixir
defmodule ImagePipe.Cache.FileSystem.SketchPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Cache.FileSystem.Sketch

  property "estimate(k) is always >= true count of k" do
    check all keys <- list_of(string(:alphanumeric, min_length: 1, max_length: 16), min_length: 0, max_length: 200) do
      sketch = Sketch.new(depth: 4, width: 256)
      sketch = Enum.reduce(keys, sketch, &Sketch.increment(&2, &1))
      counts = Enum.frequencies(keys)

      Enum.each(counts, fn {key, true_count} ->
        assert Sketch.estimate(sketch, key) >= true_count
      end)
    end
  end

  property "aging preserves relative ordering for keys with well-separated counts" do
    check all hot_key <- string(:alphanumeric, min_length: 1, max_length: 16),
              cold_key <- string(:alphanumeric, min_length: 1, max_length: 16),
              hot_key != cold_key do
      sketch = Sketch.new(depth: 4, width: 256)
      sketch = Enum.reduce(1..50, sketch, fn _, s -> Sketch.increment(s, hot_key) end)
      sketch = Sketch.increment(sketch, cold_key)

      hot_before = Sketch.estimate(sketch, hot_key)
      cold_before = Sketch.estimate(sketch, cold_key)
      assert hot_before > cold_before

      sketch = Sketch.age(sketch)
      hot_after = Sketch.estimate(sketch, hot_key)
      cold_after = Sketch.estimate(sketch, cold_key)
      assert hot_after >= cold_after
    end
  end
end
```

- [ ] **Step 2: Run, confirm pass**

```bash
mise exec -- mix test test/image_pipe/cache/file_system/sketch_property_test.exs
```
Expected: 2 properties passed.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/cache/file_system/sketch_property_test.exs
git commit -m "Add Sketch property tests"
```

---

### Task 6: Add the `talan` dependency and smoke-test our usage

The doorkeeper uses [`talan`](https://hex.pm/packages/talan), a Bloom
filter library backed by `:atomics`. No wrapper module — `Admission`
calls `Talan.BloomFilter` directly. This task adds the dependency and
verifies the small slice of the API we depend on works as expected.

**Files:**
- Modify: `mix.exs`
- Create: `test/image_pipe/cache/file_system/doorkeeper_usage_test.exs`

- [ ] **Step 1: Add `talan` to `mix.exs` deps**

```elixir
# mix.exs (inside deps/0)
{:talan, "~> 0.2.1"},
```

- [ ] **Step 2: Fetch the dependency**

```bash
mise exec -- mix deps.get
```

Expected: `talan`, `abit`, and `murmur` are fetched.

- [ ] **Step 3: Write a smoke test covering our usage of `Talan.BloomFilter`**

```elixir
defmodule ImagePipe.Cache.FileSystem.DoorkeeperUsageTest do
  @moduledoc """
  Smoke tests for our usage of `Talan.BloomFilter`. We don't re-test
  talan's correctness — we verify the specific API slice we depend on
  behaves as expected for our usage pattern.
  """
  use ExUnit.Case, async: true

  test "new + put + member? round-trip" do
    bf = Talan.BloomFilter.new(8192, false_positive_probability: 0.01)
    :ok = Talan.BloomFilter.put(bf, "key-1")
    assert Talan.BloomFilter.member?(bf, "key-1")
    refute Talan.BloomFilter.member?(bf, "key-not-present-yet")
  end

  test "reset via discard-and-allocate produces an empty filter" do
    bf = Talan.BloomFilter.new(8192, false_positive_probability: 0.01)
    :ok = Talan.BloomFilter.put(bf, "key-1")
    assert Talan.BloomFilter.member?(bf, "key-1")

    # Reset = create a new filter; old atomics ref becomes garbage.
    fresh = Talan.BloomFilter.new(8192, false_positive_probability: 0.01)
    refute Talan.BloomFilter.member?(fresh, "key-1")
  end

  test "put is mutative: same ref carries state forward" do
    # This documents (and guards) our reliance on the in-place semantics:
    # we hold one Talan.BloomFilter struct in Admission state and rely on
    # put mutating the underlying atomics ref.
    bf = Talan.BloomFilter.new(8192, false_positive_probability: 0.01)
    :ok = Talan.BloomFilter.put(bf, "alpha")
    :ok = Talan.BloomFilter.put(bf, "beta")
    assert Talan.BloomFilter.member?(bf, "alpha")
    assert Talan.BloomFilter.member?(bf, "beta")
  end
end
```

- [ ] **Step 4: Run, confirm pass**

```bash
mise exec -- mix test test/image_pipe/cache/file_system/doorkeeper_usage_test.exs
```

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock test/image_pipe/cache/file_system/doorkeeper_usage_test.exs
git commit -m "Add talan dependency for doorkeeper Bloom filter"
```

---

### Task 7: Policy — scoring

**Files:**
- Create: `lib/image_pipe/cache/file_system/policy.ex`
- Create: `test/image_pipe/cache/file_system/policy_test.exs`

- [ ] **Step 1: Write failing tests for `score/1` and `weighted_avg_score/1`**

```elixir
defmodule ImagePipe.Cache.FileSystem.PolicyTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem.Policy

  defp descriptor(opts) do
    %{
      key_hash: Keyword.get(opts, :key_hash, "h"),
      size_bytes: Keyword.fetch!(opts, :size_bytes),
      body_sha256: Keyword.get(opts, :body_sha256, "s"),
      cost_us: Keyword.get(opts, :cost_us, 1000)
    }
  end

  describe "score/2" do
    test "is a float for normal inputs" do
      d = descriptor(size_bytes: 1_000, cost_us: 10_000)
      assert is_float(Policy.score(d, _freq = 3))
    end

    test "captures value-per-byte" do
      small_expensive = descriptor(size_bytes: 1_000, cost_us: 50_000)
      large_cheap = descriptor(size_bytes: 1_000_000, cost_us: 50_000)

      assert Policy.score(small_expensive, 1) > Policy.score(large_cheap, 1)
    end

    test "cost_us=0 falls back to size_bytes (frequency-only scoring)" do
      d = descriptor(size_bytes: 1_000_000, cost_us: 0)
      # Expected: score = freq * size / size = freq (as float)
      assert_in_delta Policy.score(d, 5), 5.0, 0.0001
    end

    test "handles size_bytes=0 safely (uses max(size, 1))" do
      d = descriptor(size_bytes: 0, cost_us: 1000)
      assert is_float(Policy.score(d, 1))
    end
  end

  describe "weighted_avg_score/2" do
    test "returns 0.0 for empty victim list" do
      assert Policy.weighted_avg_score([], fn _ -> 0 end) == 0.0
    end

    test "computes value-per-byte across a victim set" do
      v1 = descriptor(size_bytes: 100, cost_us: 1_000)
      v2 = descriptor(size_bytes: 200, cost_us: 2_000)
      freq_fn = fn _ -> 1 end

      # sum(freq * cost) = 1*1000 + 1*2000 = 3000
      # sum(size) = 300
      # weighted_avg = 3000/300 = 10.0
      assert_in_delta Policy.weighted_avg_score([v1, v2], freq_fn), 10.0, 0.0001
    end
  end
end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement Policy scoring**

```elixir
defmodule ImagePipe.Cache.FileSystem.Policy do
  @moduledoc false

  @type descriptor :: %{
          key_hash: binary(),
          size_bytes: non_neg_integer(),
          body_sha256: binary(),
          cost_us: non_neg_integer()
        }

  @doc """
  Compute the cost-aware score for an entry given its frequency.

  score = freq × effective_cost / max(size_bytes, 1)

  effective_cost = cost_us when cost_us > 0, else size_bytes (size-neutral
  fallback that collapses scoring to freq alone).
  """
  @spec score(descriptor(), non_neg_integer()) :: float()
  def score(%{cost_us: cost_us, size_bytes: size_bytes}, freq) do
    effective_cost = if cost_us > 0, do: cost_us, else: size_bytes
    freq * effective_cost / max(size_bytes, 1)
  end

  @doc """
  Compute the weighted-average value-per-byte across a list of victim
  descriptors. Weighting is by size_bytes. Returns 0.0 for empty input.

  freq_fn maps a descriptor's key_hash to its current frequency.
  """
  @spec weighted_avg_score([descriptor()], (binary() -> non_neg_integer())) :: float()
  def weighted_avg_score([], _freq_fn), do: 0.0

  def weighted_avg_score(victims, freq_fn) when is_list(victims) do
    {numerator, denominator} =
      Enum.reduce(victims, {0, 0}, fn v, {num, den} ->
        freq = freq_fn.(v.key_hash)
        effective_cost = if v.cost_us > 0, do: v.cost_us, else: v.size_bytes
        {num + freq * effective_cost, den + v.size_bytes}
      end)

    if denominator == 0, do: 0.0, else: numerator / denominator
  end
end
```

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/policy.ex test/image_pipe/cache/file_system/policy_test.exs
git commit -m "Add Policy scoring with cost-aware float arithmetic"
```

---

### Task 8: Policy — main gate (victim walk + admit decision)

**Files:**
- Modify: `lib/image_pipe/cache/file_system/policy.ex`
- Modify: `test/image_pipe/cache/file_system/policy_test.exs`

- [ ] **Step 1: Write failing tests for `victim_walk/4` and `admit?/3`**

Append to test file:

```elixir
  describe "victim_walk/4" do
    test "walks probationary LRU outward until enough bytes" do
      probationary = [
        descriptor(key_hash: "lru", size_bytes: 100),
        descriptor(key_hash: "mid", size_bytes: 100),
        descriptor(key_hash: "mru", size_bytes: 100)
      ]
      protected = []

      assert {:ok, [v1]} = Policy.victim_walk(probationary, protected, 100, 64)
      assert v1.key_hash == "lru"

      assert {:ok, [v1, v2]} = Policy.victim_walk(probationary, protected, 150, 64)
      assert [v1.key_hash, v2.key_hash] == ["lru", "mid"]
    end

    test "extends into protected LRU when probationary exhausted" do
      probationary = [descriptor(key_hash: "p_lru", size_bytes: 100)]
      protected = [descriptor(key_hash: "prot_lru", size_bytes: 200)]

      assert {:ok, victims} = Policy.victim_walk(probationary, protected, 250, 64)
      assert Enum.map(victims, & &1.key_hash) == ["p_lru", "prot_lru"]
    end

    test "returns :no_evictable_victims when both queues together cannot free enough" do
      probationary = [descriptor(size_bytes: 50)]
      protected = [descriptor(size_bytes: 50)]
      assert {:error, :no_evictable_victims} = Policy.victim_walk(probationary, protected, 200, 64)
    end

    test "returns :victim_limit_exceeded when freeing enough bytes requires more victims than the limit" do
      # 10 victims × 100 bytes = 1000 bytes available, but limit is 3.
      probationary = for i <- 1..10, do: descriptor(key_hash: "k#{i}", size_bytes: 100)
      assert {:error, :victim_limit_exceeded} =
               Policy.victim_walk(probationary, [], 500, 3)
    end
  end

  describe "admit?/3" do
    test "admits when candidate score exceeds weighted-average victim score" do
      candidate = descriptor(key_hash: "c", size_bytes: 100, cost_us: 50_000)
      victims = [descriptor(key_hash: "v", size_bytes: 100, cost_us: 1_000)]
      freq_fn = fn _ -> 1 end

      assert Policy.admit?(candidate, victims, freq_fn) == true
    end

    test "rejects when candidate score is below weighted-average victim score" do
      candidate = descriptor(key_hash: "c", size_bytes: 100, cost_us: 1_000)
      victims = [descriptor(key_hash: "v", size_bytes: 100, cost_us: 50_000)]
      freq_fn = fn _ -> 1 end

      assert Policy.admit?(candidate, victims, freq_fn) == false
    end

    test "admits unconditionally when victim list is empty (no comparison needed)" do
      candidate = descriptor(size_bytes: 100, cost_us: 1)
      assert Policy.admit?(candidate, [], fn _ -> 0 end) == true
    end
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `victim_walk/4` and `admit?/3`**

```elixir
  @doc """
  Walk probationary LRU outward, then protected LRU outward, collecting
  victims until cumulative size_bytes >= needed_bytes.

  Probationary and protected lists must be ordered LRU-first. The
  `limit` parameter caps the number of victims collected — if more
  would be needed to free enough bytes, returns
  `{:error, :victim_limit_exceeded}`.

  Returns:
  - `{:ok, victims}` — enough bytes can be freed within the limit
  - `{:error, :no_evictable_victims}` — both queues combined cannot
    free enough bytes
  - `{:error, :victim_limit_exceeded}` — freeing enough bytes would
    require more than `limit` victims
  """
  @spec victim_walk([descriptor()], [descriptor()], non_neg_integer(), pos_integer()) ::
          {:ok, [descriptor()]}
          | {:error, :no_evictable_victims}
          | {:error, :victim_limit_exceeded}
  def victim_walk(probationary, protected, needed_bytes, limit)
      when is_list(probationary) and is_list(protected) and
             is_integer(needed_bytes) and needed_bytes >= 0 and
             is_integer(limit) and limit > 0 do
    case take_until_bytes(probationary, needed_bytes, [], 0, limit) do
      {:done, victims} ->
        {:ok, Enum.reverse(victims)}

      {:short, victims, still_needed} ->
        protected_limit = limit - length(victims)

        if protected_limit <= 0 do
          {:error, :victim_limit_exceeded}
        else
          case take_until_bytes(protected, still_needed, victims, 0, protected_limit) do
            {:done, all_victims} -> {:ok, Enum.reverse(all_victims)}
            {:short, _all_victims, _remaining} -> {:error, :no_evictable_victims}
            :limit_exceeded -> {:error, :victim_limit_exceeded}
          end
        end

      :limit_exceeded ->
        {:error, :victim_limit_exceeded}
    end
  end

  # Returns one of: {:done, victims}, {:short, victims, still_needed_bytes},
  # or :limit_exceeded.
  defp take_until_bytes([], remaining, victims, acc, _limit),
    do: {:short, victims, remaining - acc}

  defp take_until_bytes(_list, remaining, victims, acc, _limit) when acc >= remaining,
    do: {:done, victims}

  defp take_until_bytes(_list, _remaining, victims, _acc, limit)
       when length(victims) >= limit,
       do: :limit_exceeded

  defp take_until_bytes([v | rest], remaining, victims, acc, limit) do
    take_until_bytes(rest, remaining, [v | victims], acc + v.size_bytes, limit)
  end

  @doc """
  Decide whether a candidate should be admitted given the victims it would
  displace. Empty victim list (free space available) always admits.

  freq_fn maps a key_hash to its current frequency estimate.
  """
  @spec admit?(descriptor(), [descriptor()], (binary() -> non_neg_integer())) :: boolean()
  def admit?(_candidate, [], _freq_fn), do: true

  def admit?(candidate, victims, freq_fn) do
    candidate_freq = freq_fn.(candidate.key_hash)
    score(candidate, candidate_freq) > weighted_avg_score(victims, freq_fn)
  end
```

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/policy.ex test/image_pipe/cache/file_system/policy_test.exs
git commit -m "Add Policy victim walk and weighted-average admit decision"
```

---

## Phase 2: Metadata threading

### Task 9: Add `cost_us` to `Entry.Metadata`

**Files:**
- Modify: `lib/image_pipe/cache/entry/metadata.ex`
- Modify: `lib/image_pipe/cache/sink.ex` (build/4 includes cost_us)

**No dedicated test for this task.** A test that builds a `%Metadata{}`
and asserts `meta.cost_us == 12_345`, or that the default is `0`, only
re-states the `defstruct` definition the compiler already enforces — a
field-existence test the project guidelines reject. The `cost_us`
behavior that actually matters is covered downstream by real
producer/consumer tests: Task 10 round-trips it through the meta file
(`commit_sink` → `get/2`), and Task 7 covers the `cost_us == 0 →
size-neutral score` fallback. This task is a pure struct change; the
first task that consumes it carries the test.

- [ ] **Step 1: Add `cost_us` to `Entry.Metadata`**

```elixir
defmodule ImagePipe.Cache.Entry.Metadata do
  @moduledoc false

  alias ImagePipe.Cache.Entry

  @enforce_keys [:content_type, :headers, :created_at, :output_format]
  defstruct [:content_type, :headers, :created_at, :output_format, cost_us: 0]

  @type t :: %__MODULE__{
          content_type: String.t(),
          headers: [Entry.header()],
          created_at: DateTime.t(),
          output_format: atom(),
          cost_us: non_neg_integer()
        }
end
```

- [ ] **Step 2: Compile, confirm no warnings** (no test; covered downstream by Task 10/Task 7)

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe/cache/entry/metadata.ex
git commit -m "Add cost_us field to Entry.Metadata"
```

---

### Task 10: Thread `cost_us` through Sink and persist to meta file

**Files:**
- Modify: `lib/image_pipe/cache/sink.ex`
- Modify: `lib/image_pipe/cache/file_system.ex`
- Modify: `test/image_pipe/cache/file_system_test.exs` (add a test that `cost_us` round-trips)

- [ ] **Step 1: Write failing test verifying cost_us survives commit and is read back**

Append to `test/image_pipe/cache/file_system_test.exs`:

```elixir
  describe "cost_us metadata" do
    test "is persisted in the meta file and returned on hit", %{tmp_dir: tmp_dir} do
      key = key()
      opts = [root: tmp_dir]
      entry = entry()
      metadata =
        struct!(ImagePipe.Cache.Entry.Metadata,
          content_type: entry.content_type,
          headers: entry.headers,
          created_at: entry.created_at,
          output_format: :webp,
          cost_us: 42_000
        )

      {:ok, state} = FileSystem.open_sink(key, metadata, opts)
      {:ok, state} = FileSystem.write_chunk(state, entry.body, opts)
      :ok = FileSystem.commit_sink(state, opts)

      assert {:hit, hit_entry} = FileSystem.get(key, opts)
      # The entry struct doesn't carry cost_us today; we verify it lands in
      # the on-disk meta payload by re-reading the file directly.
      meta_path = Path.join([tmp_dir, "aa", "aa", String.duplicate("a", 64) <> ".meta"])
      meta = meta_path |> File.read!() |> :erlang.binary_to_term([:safe])
      assert meta.cost_us == 42_000
      assert hit_entry.body == entry.body
    end
  end
```

(Note: existing tests use `@tmp_dir` setup; verify the `setup` pattern in `file_system_test.exs` and adapt this test to match.)

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Add `cost_us` to the meta file payload in `file_system.ex`**

In `sink_metadata/3`, add `cost_us`:

```elixir
  defp sink_metadata(state, body_sha256, body_filename) do
    metadata = %{
      metadata_version: @metadata_version,
      content_type: state.metadata.content_type,
      headers: state.metadata.headers,
      created_at: DateTime.to_iso8601(state.metadata.created_at),
      body_byte_size: state.size,
      body_sha256: body_sha256,
      body_filename: body_filename,
      cost_us: state.metadata.cost_us
    }

    :erlang.term_to_binary(metadata, [:deterministic])
  end
```

In `validate_metadata/1`, extend the pattern to require `cost_us`:

```elixir
  defp validate_metadata(%{
         metadata_version: @metadata_version,
         content_type: content_type,
         headers: headers,
         created_at: created_at,
         body_byte_size: body_byte_size,
         body_sha256: body_sha256,
         body_filename: body_filename,
         cost_us: cost_us
       })
       when is_binary(content_type) and is_list(headers) and is_binary(created_at) and
              is_integer(body_byte_size) and body_byte_size >= 0 and is_binary(body_sha256) and
              is_binary(body_filename) and is_integer(cost_us) and cost_us >= 0 do
    # ... rest unchanged, but include cost_us in the returned map
  end
```

And include `cost_us` in the returned metadata map so callers can read it.

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system.ex test/image_pipe/cache/file_system_test.exs
git commit -m "Persist cost_us in cache meta file and validate on read"
```

---

### Task 11: Capture `cost_us` via SourceSession-tracked monotonic time

**Files:**
- Modify: `lib/image_pipe/cache/sink.ex`
- Modify: `lib/image_pipe/request/source_session.ex`

`cost_us` is the wall-clock time from source-fetch start to the moment
the cache sink commits. The existing telemetry stage spans
(`[:source, :fetch, ...]`, `[:transform, :execute, ...]`, `[:encode,
...]`) are NOT a viable data source: their `:stop` events don't all
fire before `commit_sink` runs, and there's no existing context
plumbing into `Sink.open/5`. Instead, measure manually in
`SourceSession` via `System.monotonic_time/1` checkpoints.

- [ ] **Step 1: Write a test that verifies `cost_us` threads from opts into the adapter's metadata**

Do not hand-build a bespoke stub adapter or a fake `%Resolved{}`/`%Key{}`.
`Cache.open_sink/3` is the real public entry, `ImagePipe.Cache` is a
host-implementable behaviour, and `test/image_pipe/cache_test.exs`
already exercises `open_sink` through it with the `SinkMissAdapter`
capture adapter and the `cache_key/0` + `resolved_output/0` helpers.
Extend that file the same way — add a sibling to the existing
"open_sink builds body-free metadata from resolved output" test:

```elixir
test "open_sink threads cost_us from opts into adapter metadata" do
  Cache.open_sink(
    cache_key(),
    resolved_output(),
    cache: {SinkMissAdapter, test_pid: self()},
    cost_us: 42_000
  )

  assert_received {:open_sink, %Key{}, %Entry.Metadata{cost_us: 42_000}, _adapter_opts}
end
```

`cost_us` rides in the full `opts` list (the same list that carries
`:cache`), not in the adapter's `cache_opts`. `Cache.open_sink/3` passes
that list straight through to `Sink.open/5`, so the value is available
where Step 3 reads it.

- [ ] **Step 2: Run, confirm failure** (cost_us isn't extracted from opts yet, and `Entry.Metadata` has no `:cost_us` field until Task 10)

- [ ] **Step 3: Modify `Sink.open/5` to read `:cost_us` from `opts`**

In `lib/image_pipe/cache/sink.ex`:

```elixir
  def open(adapter, %Key{} = key, %Resolved{} = resolved_output, cache_opts, opts) do
    cost_us = Keyword.get(opts, :cost_us, 0)

    with {:ok, metadata} <- response_metadata(resolved_output, cost_us),
         {:ok, adapter_state} <- open_adapter_sink(adapter, key, metadata, cache_opts) do
      build(adapter, key, metadata, cache_opts, adapter_state)
    else
      {:error, reason} ->
        handle_open_error(reason, resolved_output.format, opts)
        nil
    end
  end

  defp response_metadata(%Resolved{} = resolved_output, cost_us) do
    with {:ok, headers} <- Entry.cacheable_headers(resolved_output.response_headers) do
      {:ok,
       %Entry.Metadata{
         content_type: Format.mime_type!(resolved_output.format),
         headers: headers,
         created_at: DateTime.utc_now(),
         output_format: resolved_output.format,
         cost_us: cost_us
       }}
    end
  end
```

- [ ] **Step 4: Add a monotonic-time checkpoint to `SourceSession`**

In `lib/image_pipe/request/source_session.ex`, add a `:fetch_started_at`
field to the session state (or wherever the session state lives), set
at the start of source fetch:

```elixir
  # Where the session is initialized:
  fetch_started_at: System.monotonic_time(:microsecond)
```

When the session opens the cache sink, compute elapsed time and pass it
in opts:

```elixir
  # Locate the existing Cache.open_sink call (around line 253) and add
  # cost_us to the opts:
  cost_us = System.monotonic_time(:microsecond) - session.fetch_started_at
  Cache.open_sink(key, resolved_output, Keyword.put(opts, :cost_us, cost_us))
```

This captures fetch + transform + encode (up to first chunk), which for
image encode is essentially the full encode cost since image encoders
produce the encoded binary in memory then stream it out.

- [ ] **Step 5: Add a request-boundary check that the measured cost is non-zero**

The Step 1 test proves the value threads through; it does not prove
`SourceSession` actually measures a positive elapsed time. Add a
wire-level assertion in the imgproxy conformance suite (which already
drives real `ImagePipe.call/2` cache-miss writes through
`ImgproxyWireConformanceTest.CacheProbe`, whose `open_sink/3` sends
`{:cache_open_sink, key, metadata}`). On a cache-miss request that
encodes and commits, assert the captured metadata carries a positive
cost:

```elixir
assert_received {:cache_open_sink, _key, %{cost_us: cost_us}}
assert cost_us > 0
```

This is the real producer path: `SourceSession` checkpoint →
`Cache.open_sink` opts → `Sink.open/5` → `Entry.Metadata`.

- [ ] **Step 6: Run all tests, confirm pass**

```bash
mise exec -- mix test
```

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/cache/sink.ex lib/image_pipe/request/...
git commit -m "Thread source/transform/encode stage durations into cache cost_us"
```

---

## Phase 3: Admission GenServer

This is the largest phase. The GenServer is decomposed into discrete TDD-able units.

### Task 12: Admission skeleton (state struct, `start_link`, `init`, Registry naming)

**Files:**
- Create: `lib/image_pipe/cache/file_system/admission.ex`
- Create: `test/image_pipe/cache/file_system/admission_test.exs`

- [ ] **Step 1: Write failing test for `start_link` and registration**

```elixir
defmodule ImagePipe.Cache.FileSystem.AdmissionTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem.Admission

  setup do
    # Start the per-test Registry and a private tmp cache root. A single setup
    # callback supplies both keys so every test gets a consistent context;
    # there is no second tag-gated setup to race with.
    registry_name = :"#{__MODULE__}.Registry"
    start_supervised!({Registry, keys: :unique, name: registry_name})

    tmp_dir = Path.join(System.tmp_dir!(), "admission_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{registry: registry_name, tmp_dir: tmp_dir}
  end

  test "start_link registers the process under {root, node_id}", %{registry: registry, tmp_dir: tmp_dir} do
    opts = [
      registry: registry,
      root: tmp_dir,
      node_id: "test-node",
      max_size_bytes: 1_000_000,
      window_ratio: 0.01,
      sketch_depth: 4,
      sketch_width: 256,
      doorkeeper_cardinality: 1024,
      doorkeeper_fpr: 0.01,
      state_dir: Path.join(tmp_dir, ".cache_state")
    ]
    pid = start_supervised!({Admission, opts})
    assert is_pid(pid)

    assert [{^pid, _}] = Registry.lookup(registry, {tmp_dir, "test-node"})
  end
end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement Admission skeleton**

```elixir
defmodule ImagePipe.Cache.FileSystem.Admission do
  @moduledoc false

  use GenServer

  alias ImagePipe.Cache.FileSystem.Sketch

  defmodule State do
    @moduledoc false
    defstruct [
      :registry,
      :root,
      :node_id,
      :state_dir,
      :max_size_bytes,
      :window_budget,
      :sketch_depth,
      :sketch_width,
      :aging_sample_size,
      :doorkeeper_cardinality,
      :doorkeeper_fpr,
      :eviction_victim_limit,
      :local_cms,
      :boot_cms,
      :doorkeeper,     # %Talan.BloomFilter{}
      :flush_interval_ms,
      :cleanup_interval_ms,
      :reconcile_interval_ms,
      :state_ttl_ms,
      path_prefix: "",
      window: nil,
      probationary: nil,
      protected: nil,
      window_bytes: 0,
      probationary_bytes: 0,
      protected_bytes: 0,
      next_position: 1,
      state_dirty: false,
      # populated by warm-start (Task 19), consumed by directory scan (Task 21):
      persisted_protected_hashes: [],
      # set by handle_continue (Task 20). `scan_task_ref` is the monitor
      # ref so an abnormal scan crash is observed and waiters are released
      # instead of blocking forever. `scan_complete?` flips when the scan
      # task reports done; `scan_waiters` holds `GenServer.call` `from`
      # tags queued by `await_scan/2` before completion.
      scan_task: nil,
      scan_task_ref: nil,
      scan_complete?: false,
      scan_waiters: []
    ]
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via_tuple(opts))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :root), Keyword.fetch!(opts, :node_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  defp via_tuple(opts) do
    registry = Keyword.fetch!(opts, :registry)
    root = Keyword.fetch!(opts, :root)
    node_id = Keyword.fetch!(opts, :node_id)
    {:via, Registry, {registry, {root, node_id}}}
  end

  @impl true
  def init(opts) do
    max_size = Keyword.fetch!(opts, :max_size_bytes)
    window_ratio = Keyword.fetch!(opts, :window_ratio)
    sketch_depth = Keyword.fetch!(opts, :sketch_depth)
    sketch_width = Keyword.fetch!(opts, :sketch_width)
    # Aging cadence is decoupled from width (Sketch.new/1 docs). Fall back to
    # width * 10 only for direct-start unit tests that don't pass it.
    aging_sample_size = Keyword.get(opts, :aging_sample_size, sketch_width * 10)
    doorkeeper_cardinality = Keyword.fetch!(opts, :doorkeeper_cardinality)
    doorkeeper_fpr = Keyword.fetch!(opts, :doorkeeper_fpr)

    state = %State{
      registry: Keyword.fetch!(opts, :registry),
      root: Keyword.fetch!(opts, :root),
      node_id: Keyword.fetch!(opts, :node_id),
      state_dir: Keyword.fetch!(opts, :state_dir),
      # path_prefix mirrors the adapter option so the directory scan (Task 20)
      # walks the same partition root the adapter writes to. Defaults to "".
      path_prefix: Keyword.get(opts, :path_prefix, ""),
      max_size_bytes: max_size,
      window_budget: trunc(max_size * window_ratio),
      sketch_depth: sketch_depth,
      sketch_width: sketch_width,
      aging_sample_size: aging_sample_size,
      doorkeeper_cardinality: doorkeeper_cardinality,
      doorkeeper_fpr: doorkeeper_fpr,
      # Bounded eviction fan-out per admission (Task 25 config; default 64).
      # Defaulted here so direct-start unit tests need not pass it.
      eviction_victim_limit: Keyword.get(opts, :eviction_victim_limit, 64),
      local_cms: Sketch.new(depth: sketch_depth, width: sketch_width, sample_size: aging_sample_size),
      boot_cms: Sketch.new(depth: sketch_depth, width: sketch_width, sample_size: aging_sample_size),
      doorkeeper: Talan.BloomFilter.new(doorkeeper_cardinality, false_positive_probability: doorkeeper_fpr),
      flush_interval_ms: Keyword.get(opts, :flush_interval_ms, 30_000),
      cleanup_interval_ms: Keyword.get(opts, :cleanup_interval_ms, 3_600_000),
      reconcile_interval_ms: Keyword.get(opts, :reconcile_interval_ms, 60_000),
      state_ttl_ms: Keyword.get(opts, :state_ttl_ms, 604_800_000),
      window: :ets.new(:window, [:ordered_set, :private]),
      probationary: :ets.new(:probationary, [:ordered_set, :private]),
      protected: :ets.new(:protected, [:ordered_set, :private])
    }

    {:ok, state}
  end
end
```

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/admission.ex test/image_pipe/cache/file_system/admission_test.exs
git commit -m "Add Admission GenServer skeleton with Registry naming"
```

---

### Task 13: Admission `hit/2` cast with doorkeeper-gated CMS

**Files:**
- Modify: `lib/image_pipe/cache/file_system/admission.ex`
- Modify: `test/image_pipe/cache/file_system/admission_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
  test "hit/2 marks the key in doorkeeper on first sighting, increments CMS on second", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, sketch_width: 64)
    pid = start_supervised!({Admission, opts})

    descriptor = %{key_hash: "key-1", size_bytes: 100, body_sha256: "s", cost_us: 1_000}

    Admission.hit(pid, descriptor)
    state = :sys.get_state(pid)
    assert Talan.BloomFilter.member?(state.doorkeeper, "key-1")
    assert Sketch.estimate(state.local_cms, "key-1") == 0

    Admission.hit(pid, descriptor)
    state = :sys.get_state(pid)
    assert Sketch.estimate(state.local_cms, "key-1") >= 1
  end

  test "hit/2 on untracked key synthesizes a probationary entry from the descriptor", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    descriptor = %{key_hash: "cold", size_bytes: 5_000, body_sha256: "s", cost_us: 1_000}
    Admission.hit(pid, descriptor)
    state = :sys.get_state(pid)

    assert in_queue?(state.probationary, "cold")
    assert state.probationary_bytes == 5_000
  end

  defp base_opts(overrides) do
    Keyword.merge(
      [
        registry: overrides[:registry],
        root: overrides[:tmp_dir],
        node_id: "test-node",
        state_dir: Path.join(overrides[:tmp_dir], ".cache_state"),
        max_size_bytes: overrides[:max_size_bytes] || 1_000_000,
        window_ratio: overrides[:window_ratio] || 0.01,
        sketch_depth: 4,
        sketch_width: overrides[:sketch_width] || 256,
        doorkeeper_cardinality: overrides[:doorkeeper_cardinality] || 1024,
        doorkeeper_fpr: overrides[:doorkeeper_fpr] || 0.01
      ],
      []
    )
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `hit/2`**

```elixir
  @doc """
  Notify Admission of a cache hit. `descriptor` carries the same shape
  as an admit-time descriptor (key_hash, size_bytes, body_sha256,
  cost_us) so Admission can synthesize a probationary entry for hits
  that arrive before the boot scan reaches the corresponding key.
  """
  @spec hit(pid() | GenServer.name(), map()) :: :ok
  def hit(server, descriptor) when is_map(descriptor) do
    GenServer.cast(server, {:hit, descriptor})
  end

  @impl true
  def handle_cast({:hit, descriptor}, state) do
    state = sighting(state, descriptor.key_hash)
    state = on_hit_promote_or_synthesize(state, descriptor)
    {:noreply, %{state | state_dirty: true}}
  end

  defp on_hit_promote_or_synthesize(state, descriptor) do
    case locate(state, descriptor.key_hash) do
      nil ->
        # Cold-boot hit synthesis: scan hasn't reached this entry yet,
        # but the adapter has just read its meta and passed a full
        # descriptor. Insert at probationary MRU.
        {pos, state} = next_position(state)
        :ets.insert(state.probationary, {{pos, descriptor.key_hash}, descriptor})
        Map.update!(state, :probationary_bytes, &(&1 + descriptor.size_bytes))

      _located ->
        promote_on_hit(state, descriptor.key_hash)
    end
  end

  defp sighting(state, key_hash) do
    if Talan.BloomFilter.member?(state.doorkeeper, key_hash) do
      %{state | local_cms: Sketch.increment(state.local_cms, key_hash)}
    else
      # talan's put/2 mutates the underlying :atomics ref in place and
      # returns :ok.
      :ok = Talan.BloomFilter.put(state.doorkeeper, key_hash)
      state
    end
  end
```

Note: `promote_on_hit/2` is added in Task 17; for this task's tests,
the descriptor-with-locate-or-synthesize path is exercised.

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/admission.ex test/image_pipe/cache/file_system/admission_test.exs
git commit -m "Add Admission.hit/2 with doorkeeper-gated CMS increment"
```

---

### Task 14: Admission `admit/2` — main gate happy path

**Files:**
- Modify: `lib/image_pipe/cache/file_system/admission.ex`
- Modify: `test/image_pipe/cache/file_system/admission_test.exs`

- [ ] **Step 1: Write failing test for the simplest admission flow**

```elixir
  test "admit/2 inserts a candidate at window MRU when window has room", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    descriptor = %{
      key_hash: "h1",
      size_bytes: 5_000,
      body_sha256: "sha1",
      cost_us: 1_000
    }

    assert {:admit, []} = Admission.admit(pid, descriptor)

    state = :sys.get_state(pid)
    assert state.window_bytes == 5_000
  end

  test "admit/2 hard-rejects candidates larger than max_size_bytes", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    descriptor = %{
      key_hash: "huge",
      size_bytes: 10_000_000,  # > 1_000_000 cap
      body_sha256: "sha",
      cost_us: 1_000
    }

    assert {:reject, :over_cap} = Admission.admit(pid, descriptor)
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `admit/2` with window-insert and hard-reject**

```elixir
  @spec admit(pid() | GenServer.name(), map()) ::
          {:admit, [map()]} | {:reject, :over_cap | :score_too_low | :no_evictable_victims}
  def admit(server, descriptor) do
    GenServer.call(server, {:admit, descriptor})
  end

  @impl true
  def handle_call({:admit, descriptor}, _from, state) do
    # Increment sighting first (commit is itself a sighting of the key)
    state = sighting(state, descriptor.key_hash)

    cond do
      descriptor.size_bytes > state.max_size_bytes ->
        {:reply, {:reject, :over_cap}, state}

      true ->
        {result, state} = do_admit(state, descriptor)
        {:reply, result, %{state | state_dirty: true}}
    end
  end

  defp do_admit(state, descriptor) do
    cond do
      descriptor.size_bytes > state.window_budget ->
        run_main_gate(state, descriptor)

      already_tracked?(state, descriptor.key_hash) ->
        same_key_replace(state, descriptor)

      true ->
        insert_into_window(state, descriptor)
    end
  end

  defp insert_into_window(state, descriptor) do
    {position, state} = next_position(state)
    :ets.insert(state.window, {{position, descriptor.key_hash}, descriptor})

    state = %{
      state
      | window_bytes: state.window_bytes + descriptor.size_bytes
    }

    # Stub: handle window overflow in a later task.
    {{:admit, []}, state}
  end

  defp next_position(state), do: {state.next_position, %{state | next_position: state.next_position + 1}}

  defp already_tracked?(state, key_hash) do
    # Search across all queues. Inefficient but correct; optimized later.
    in_queue?(state.window, key_hash) or in_queue?(state.probationary, key_hash) or
      in_queue?(state.protected, key_hash)
  end

  defp in_queue?(table, key_hash) do
    :ets.match_object(table, {{:_, key_hash}, :_}) != []
  end

  defp run_main_gate(state, descriptor), do: {{:admit, []}, state}  # stub for next task
  defp same_key_replace(state, descriptor), do: {{:admit, []}, state}  # stub for next task
```

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/admission.ex test/image_pipe/cache/file_system/admission_test.exs
git commit -m "Add Admission.admit/2 with window insertion and hard-reject path"
```

---

### Task 15: Admission — window overflow + main gate

**Files:**
- Modify: `lib/image_pipe/cache/file_system/admission.ex`
- Modify: `test/image_pipe/cache/file_system/admission_test.exs`

- [ ] **Step 1: Write failing tests covering window overflow → main admission**

```elixir
  test "window overflow pushes LRU into main; with free main, evictee goes to probationary", %{registry: registry, tmp_dir: tmp_dir} do
    # Tiny window so we can force overflow quickly.
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, max_size_bytes: 100_000, window_ratio: 0.1)
    pid = start_supervised!({Admission, opts})

    # window_budget = 10_000. Insert 3 × 5_000-byte entries; the third pushes the first out.
    Admission.admit(pid, %{key_hash: "a", size_bytes: 5_000, body_sha256: "sa", cost_us: 1_000})
    Admission.admit(pid, %{key_hash: "b", size_bytes: 5_000, body_sha256: "sb", cost_us: 1_000})
    {:admit, victims} = Admission.admit(pid, %{key_hash: "c", size_bytes: 5_000, body_sha256: "sc", cost_us: 1_000})

    # No victims: main had room for "a".
    assert victims == []

    state = :sys.get_state(pid)
    assert state.window_bytes == 10_000  # "b" and "c"
    assert state.probationary_bytes == 5_000  # "a" moved into main
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement window overflow + main gate**

```elixir
  defp insert_into_window(state, descriptor) do
    {position, state} = next_position(state)
    :ets.insert(state.window, {{position, descriptor.key_hash}, descriptor})
    state = %{state | window_bytes: state.window_bytes + descriptor.size_bytes}
    drain_window_overflow(state, [])
  end

  defp drain_window_overflow(state, victims) do
    cond do
      state.window_bytes <= state.window_budget ->
        {{:admit, victims}, state}

      # Defensive: byte counter says we are over budget but the table is
      # empty. This should not happen if accounting is consistent, but a
      # blind `:ets.first/1` + `:ets.lookup/2` on an empty table would
      # match `[]` against `[{...}]` and crash the GenServer. Stop draining.
      :ets.first(state.window) == :"$end_of_table" ->
        {{:admit, victims}, state}

      true ->
        # Pop window LRU
        first_key = :ets.first(state.window)
        [{{pos, hash}, descriptor}] = :ets.lookup(state.window, first_key)
        :ets.delete(state.window, {pos, hash})
        state = %{state | window_bytes: state.window_bytes - descriptor.size_bytes}

        {gate_result, state} = run_main_gate(state, descriptor)

        drain_after_gate(state, descriptor, gate_result, victims)
    end
  end

  defp drain_after_gate(state, descriptor, gate_result, victims) do
    case gate_result do
      {:admit, more_victims} ->
        drain_window_overflow(state, victims ++ more_victims)

      {:reject, _} ->
        # Window evictee lost main gate; its files must be deleted
        # (body and meta).
        evictee_victim = full_eviction_victim(descriptor)
        drain_window_overflow(state, victims ++ [evictee_victim])
    end
  end

  defp full_eviction_victim(descriptor) do
    %{
      key_hash: descriptor.key_hash,
      body_sha256: descriptor.body_sha256,
      size_bytes: descriptor.size_bytes,
      delete_body?: true,
      delete_meta?: true
    }
  end

  defp run_main_gate(state, descriptor) do
    # Clamp to 0: in-flight commit overshoot or restart reconciliation can
    # transiently push (probationary + protected) above the main budget, in
    # which case the raw subtraction goes negative. A negative `available`
    # must not be treated as "room" by the `>=` comparison below, and it must
    # not let a zero-byte descriptor slip through the free-space branch and
    # skip scoring.
    available =
      max(0, state.max_size_bytes - state.window_budget - state.probationary_bytes - state.protected_bytes)

    if available >= descriptor.size_bytes do
      insert_into_probationary(state, descriptor)
    else
      identify_and_score(state, descriptor)
    end
  end

  defp insert_into_probationary(state, descriptor) do
    {position, state} = next_position(state)
    :ets.insert(state.probationary, {{position, descriptor.key_hash}, descriptor})
    state = %{state | probationary_bytes: state.probationary_bytes + descriptor.size_bytes}
    {{:admit, []}, state}
  end

  defp identify_and_score(state, descriptor) do
    probationary_list = ordered_set_to_list(state.probationary)
    protected_list = ordered_set_to_list(state.protected)
    limit = state.eviction_victim_limit

    case ImagePipe.Cache.FileSystem.Policy.victim_walk(probationary_list, protected_list, descriptor.size_bytes, limit) do
      {:error, :no_evictable_victims} ->
        {{:reject, :no_evictable_victims}, state}

      {:error, :victim_limit_exceeded} ->
        {{:reject, :victim_limit_exceeded}, state}

      {:ok, victim_descriptors} ->
        freq_fn = fn key_hash ->
          Sketch.estimate(state.local_cms, key_hash) + Sketch.estimate(state.boot_cms, key_hash)
        end

        if ImagePipe.Cache.FileSystem.Policy.admit?(descriptor, victim_descriptors, freq_fn) do
          state = remove_victims(state, victim_descriptors)
          {_result, state} = insert_into_probationary(state, descriptor)
          # Tag victims with full-eviction flags for the adapter.
          tagged = Enum.map(victim_descriptors, &full_eviction_victim/1)
          {{:admit, tagged}, state}
        else
          {{:reject, :score_too_low}, state}
        end
    end
  end

  defp ordered_set_to_list(table) do
    :ets.foldr(fn {_pos_and_hash, descriptor}, acc -> [descriptor | acc] end, [], table)
    |> Enum.reverse()
  end

  defp remove_victims(state, victims) do
    Enum.reduce(victims, state, fn descriptor, acc ->
      remove_descriptor(acc, descriptor)
    end)
  end

  defp remove_descriptor(state, descriptor) do
    # Search all queues for the descriptor and remove it. Update byte counters.
    Enum.reduce_while([:window, :probationary, :protected], state, fn queue, acc ->
      table = Map.fetch!(acc, queue)
      case :ets.match_object(table, {{:_, descriptor.key_hash}, :_}) do
        [] ->
          {:cont, acc}

        [{key, _value}] ->
          :ets.delete(table, key)
          bytes_field = :"#{queue}_bytes"
          acc = Map.update!(acc, bytes_field, &(&1 - descriptor.size_bytes))
          {:halt, acc}
      end
    end)
  end
```

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/admission.ex test/image_pipe/cache/file_system/admission_test.exs
git commit -m "Add Admission window overflow and main gate logic"
```

---

### Task 16: Admission — same-key re-commit replacement

**Files:**
- Modify: `lib/image_pipe/cache/file_system/admission.ex`
- Modify: `test/image_pipe/cache/file_system/admission_test.exs`

- [ ] **Step 1: Write failing tests for same-key re-commit behavior**

```elixir
  test "same-key re-commit returns body-only victim when body_sha256 differs", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    {:admit, []} = Admission.admit(pid, %{key_hash: "k", size_bytes: 1_000, body_sha256: "sha_old", cost_us: 1_000})
    {:admit, victims} = Admission.admit(pid, %{key_hash: "k", size_bytes: 1_500, body_sha256: "sha_new", cost_us: 2_000})

    # The victim must point at the OLD body (for deletion) but NOT
    # delete the meta — the meta path is identical for old and new
    # entries, and the adapter has just renamed the new meta into
    # place. Deleting the meta would destroy the new entry.
    assert [%{
      key_hash: "k",
      body_sha256: "sha_old",
      delete_body?: true,
      delete_meta?: false
    }] = victims
  end

  test "same-key re-commit emits NO victim when body_sha256 matches", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    {:admit, []} = Admission.admit(pid, %{key_hash: "k", size_bytes: 1_000, body_sha256: "same_sha", cost_us: 1_000})
    {:admit, victims} = Admission.admit(pid, %{key_hash: "k", size_bytes: 1_000, body_sha256: "same_sha", cost_us: 1_500})

    # Content-identical rewrite: nothing to delete (the body file path
    # is the same as the just-renamed candidate body).
    assert victims == []
  end

  test "same-key replacement rejected when new size exceeds max_size_bytes", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, max_size_bytes: 10_000)
    pid = start_supervised!({Admission, opts})

    {:admit, []} = Admission.admit(pid, %{key_hash: "k", size_bytes: 1_000, body_sha256: "sa", cost_us: 1_000})
    assert {:reject, :over_cap} = Admission.admit(pid, %{key_hash: "k", size_bytes: 20_000, body_sha256: "sb", cost_us: 1_000})

    state = :sys.get_state(pid)
    # Old entry still tracked
    assert in_queue?(state.window, "k") or in_queue?(state.probationary, "k") or in_queue?(state.protected, "k")
  end

  defp in_queue?(table, key_hash) do
    :ets.match_object(table, {{:_, key_hash}, :_}) != []
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `same_key_replace/2`**

```elixir
  defp same_key_replace(state, descriptor) do
    {queue, old_position, old_descriptor} = locate(state, descriptor.key_hash)
    table = Map.fetch!(state, queue)

    # Remove the old entry's bytes from accounting.
    bytes_field = :"#{queue}_bytes"
    state = Map.update!(state, bytes_field, &(&1 - old_descriptor.size_bytes))
    :ets.delete(table, {old_position, descriptor.key_hash})

    # Insert the new descriptor at MRU in the same queue.
    {position, state} = next_position(state)
    :ets.insert(table, {{position, descriptor.key_hash}, descriptor})
    state = Map.update!(state, bytes_field, &(&1 + descriptor.size_bytes))

    # Body-only victim when content changed; otherwise no victim.
    victims =
      if descriptor.body_sha256 == old_descriptor.body_sha256 do
        []
      else
        [%{
          key_hash: old_descriptor.key_hash,
          body_sha256: old_descriptor.body_sha256,
          size_bytes: old_descriptor.size_bytes,
          delete_body?: true,
          delete_meta?: false
        }]
      end

    {{:admit, victims}, state}
  end

  defp locate(state, key_hash) do
    Enum.find_value([:window, :probationary, :protected], fn queue ->
      table = Map.fetch!(state, queue)
      case :ets.match_object(table, {{:_, key_hash}, :_}) do
        [] -> nil
        [{{pos, _hash}, descriptor}] -> {queue, pos, descriptor}
      end
    end)
  end
```

And update the hard-reject case in `handle_call({:admit, ...})` to check same-key replace BEFORE size (this edits the existing clause from Task 14 — keep its `@impl true`):

```elixir
  @impl true
  def handle_call({:admit, descriptor}, _from, state) do
    state = sighting(state, descriptor.key_hash)

    cond do
      descriptor.size_bytes > state.max_size_bytes ->
        {:reply, {:reject, :over_cap}, state}

      true ->
        {result, state} = do_admit(state, descriptor)
        {:reply, result, %{state | state_dirty: true}}
    end
  end
```

(The same-key path is reached via `do_admit/2` already — see `already_tracked?/2` check there.)

**Same-key growth and the soft cap.** `same_key_replace/2` deliberately
swaps the new body in place *without* re-running the main gate, so a
larger replacement grows `probationary_bytes`/`protected_bytes` and can
push total usage over `max_size_bytes`. This is intentional: the soft cap
tolerates transient overshoot. The overshoot is reclaimed by the periodic
`:reconcile` tick (Task 18), which calls `reconcile_to_cap/2` to evict by
LRU until usage is back under cap. Do **not** add a synchronous eviction
gate to `same_key_replace/2` — that would make every cache refresh pay a
victim-walk and reintroduce the score-comparison subtleties the in-place
swap avoids.

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/admission.ex test/image_pipe/cache/file_system/admission_test.exs
git commit -m "Add Admission same-key re-commit with body_sha256 differs check"
```

---

### Task 17: Admission — hit promotion + protected demotion

**Files:**
- Modify: `lib/image_pipe/cache/file_system/admission.ex`
- Modify: `test/image_pipe/cache/file_system/admission_test.exs`

Implement: hit on probationary → protected MRU; hit on protected → protected MRU; hit on window → window MRU. Protected overflow demotes LRU to probationary.

- [ ] **Step 1: Write failing tests**

```elixir
  test "hit on probationary promotes to protected", %{registry: registry, tmp_dir: tmp_dir} do
    # Use small main budget so we can observe queue movement
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, max_size_bytes: 100_000)
    pid = start_supervised!({Admission, opts})

    descriptor = %{key_hash: "k", size_bytes: 5_000, body_sha256: "s", cost_us: 1_000}
    {:admit, []} = Admission.admit(pid, descriptor)

    # Force window→main by overflowing window
    Admission.admit(pid, %{key_hash: "filler", size_bytes: 1_000, body_sha256: "f", cost_us: 1_000})

    # hit/2 takes a full descriptor (Task 13); on a tracked key the
    # promote path uses the located descriptor and ignores these fields.
    # Promotion probationary → protected is not frequency-gated, so the
    # first hit already moves "k"; the second hit exercises the
    # protected → protected MRU path. `_ = :sys.get_state(pid)` between
    # casts ensures the first cast is processed before the second.
    Admission.hit(pid, descriptor)
    _ = :sys.get_state(pid)

    Admission.hit(pid, descriptor)
    state = :sys.get_state(pid)

    assert in_queue?(state.protected, "k")
    refute in_queue?(state.probationary, "k")
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `promote_on_hit/2` (the hit cast itself is already wired in Task 13)**

`handle_cast({:hit, descriptor}, state)` was added in Task 13 and already
calls `on_hit_promote_or_synthesize/2`, which dispatches to
`promote_on_hit/2` for keys it can locate. This task only adds the
promotion/demotion helpers — do **not** redefine the cast (a second
`handle_cast({:hit, ...})` clause would shadow Task 13's synthesis path
for cold-boot hits).

```elixir
  defp promote_on_hit(state, key_hash) do
    case locate(state, key_hash) do
      nil -> state
      {:window, pos, descriptor} -> move_to_mru(state, :window, pos, descriptor)
      {:probationary, pos, descriptor} ->
        :ets.delete(state.probationary, {pos, key_hash})
        state = Map.update!(state, :probationary_bytes, &(&1 - descriptor.size_bytes))
        insert_into_protected(state, descriptor)

      {:protected, pos, descriptor} -> move_to_mru(state, :protected, pos, descriptor)
    end
  end

  defp move_to_mru(state, queue, old_pos, descriptor) do
    table = Map.fetch!(state, queue)
    :ets.delete(table, {old_pos, descriptor.key_hash})
    {pos, state} = next_position(state)
    :ets.insert(table, {{pos, descriptor.key_hash}, descriptor})
    state
  end

  defp insert_into_protected(state, descriptor) do
    {pos, state} = next_position(state)
    :ets.insert(state.protected, {{pos, descriptor.key_hash}, descriptor})
    state = Map.update!(state, :protected_bytes, &(&1 + descriptor.size_bytes))
    enforce_protected_target(state)
  end

  defp enforce_protected_target(state) do
    main_budget = state.max_size_bytes - state.window_budget
    target = trunc(main_budget * 0.20)

    if state.protected_bytes > target and :ets.info(state.protected, :size) > 0 do
      first_key = :ets.first(state.protected)
      [{key, descriptor}] = :ets.lookup(state.protected, first_key)
      :ets.delete(state.protected, key)
      state = Map.update!(state, :protected_bytes, &(&1 - descriptor.size_bytes))

      {pos, state} = next_position(state)
      :ets.insert(state.probationary, {{pos, descriptor.key_hash}, descriptor})
      Map.update!(state, :probationary_bytes, &(&1 + descriptor.size_bytes))
    else
      state
    end
  end
```

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/admission.ex test/image_pipe/cache/file_system/admission_test.exs
git commit -m "Add hit promotion and protected demotion to Admission"
```

---

### Task 18: Admission — aging + persistence ticker

**Files:**
- Modify: `lib/image_pipe/cache/file_system/admission.ex`
- Modify: `test/image_pipe/cache/file_system/admission_test.exs`

This task adds:
1. Aging trigger after each sighting (check `Sketch.should_age?/1`, fire `Sketch.age/1` on both `local_cms` and `boot_cms`).
2. Periodic `:flush` message handler that writes `<state_dir>/<node_id>.state` if `state_dirty` is true.
3. Periodic `:cleanup` message handler that removes peer state files older than `:state_ttl_ms`.

- [ ] **Step 1: Write failing tests**

```elixir
  test "aging triggers when local CMS sample threshold is hit", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, sketch_width: 4)
    pid = start_supervised!({Admission, opts})

    # Threshold = 4 * 10 = 40 sightings
    # First sighting goes to doorkeeper; subsequent 39+ go to CMS.
    descriptor = %{key_hash: "k", size_bytes: 100, body_sha256: "s", cost_us: 1_000}
    Enum.each(1..50, fn _ -> Admission.hit(pid, descriptor) end)

    state = :sys.get_state(pid)  # synchronize
    assert state.local_cms.aging_epoch >= 1
  end

  test "flush ticker writes the state file when state is dirty", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, flush_interval_ms: 50)
    pid = start_supervised!({Admission, opts})

    Admission.hit(pid, %{key_hash: "k1", size_bytes: 100, body_sha256: "s", cost_us: 1_000})
    send(pid, :flush)
    :sys.get_state(pid)

    state_file = Path.join([tmp_dir, ".cache_state", "test-node.state"])
    assert File.exists?(state_file)
  end

  test "flush errors log + emit telemetry without crashing Admission", %{registry: registry, tmp_dir: tmp_dir} do
    # Configure state_dir to a path that can't be written to (e.g., a
    # file masquerading as a directory). Trigger flush; assert Admission
    # is still alive and serving.
    bad_state_dir = Path.join(tmp_dir, "blocker")
    File.touch!(bad_state_dir)  # regular file, not a directory

    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
            |> Keyword.put(:state_dir, bad_state_dir)

    pid = start_supervised!({Admission, opts})

    Admission.hit(pid, %{key_hash: "k1", size_bytes: 100, body_sha256: "s", cost_us: 1_000})
    send(pid, :flush)
    assert :sys.get_state(pid)  # process still alive
  end

  test "terminate/2 flushes dirty state synchronously", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    Admission.hit(pid, %{key_hash: "k1", size_bytes: 100, body_sha256: "s", cost_us: 1_000})

    # Cleanly stop the supervisor and assert the state file landed.
    ref = Process.monitor(pid)
    :ok = stop_supervised(Admission)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}

    state_file = Path.join([tmp_dir, ".cache_state", "test-node.state"])
    assert File.exists?(state_file)
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement aging trigger and flush ticker**

```elixir
  def init(opts) do
    # ... existing state construction ...
    {:ok, state, {:continue, :schedule_tickers}}
  end

  @impl true
  def handle_continue(:schedule_tickers, state) do
    Process.send_after(self(), :flush, state.flush_interval_ms)
    Process.send_after(self(), :cleanup, state.cleanup_interval_ms)
    Process.send_after(self(), :reconcile, state.reconcile_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state = maybe_flush(state)
    Process.send_after(self(), :flush, state.flush_interval_ms)
    {:noreply, state}
  end

  def handle_info(:cleanup, state) do
    state = cleanup_stale_peer_files(state)
    Process.send_after(self(), :cleanup, state.cleanup_interval_ms)
    {:noreply, state}
  end

  def handle_info(:reconcile, state) do
    # Drain soft-cap overshoot accumulated since the last tick. The main
    # source of overshoot that the synchronous admit path cannot reclaim
    # is `same_key_replace/2` (Task 16): it swaps a larger body in place
    # without re-running the main gate. `reconcile_to_cap/2` evicts by LRU
    # until total usage is back under `max_size_bytes` and deletes the
    # evicted files (via `emit_reconciliation_evictions/2`).
    state = reconcile_to_cap(state, [])
    Process.send_after(self(), :reconcile, state.reconcile_interval_ms)
    {:noreply, state}
  end

  defp sighting(state, key_hash) do
    state =
      if Talan.BloomFilter.member?(state.doorkeeper, key_hash) do
        %{state | local_cms: Sketch.increment(state.local_cms, key_hash)}
      else
        :ok = Talan.BloomFilter.put(state.doorkeeper, key_hash)
        state
      end

    if Sketch.should_age?(state.local_cms) do
      # Doorkeeper reset = discard the current filter and allocate a
      # fresh one. The old :atomics ref becomes unreferenced and is
      # garbage-collected. This is cheap (one allocation per aging cycle,
      # which is itself infrequent).
      fresh_doorkeeper =
        Talan.BloomFilter.new(state.doorkeeper_cardinality,
          false_positive_probability: state.doorkeeper_fpr
        )

      %{
        state
        | local_cms: Sketch.age(state.local_cms),
          boot_cms: Sketch.age(state.boot_cms),
          doorkeeper: fresh_doorkeeper,
          state_dirty: true
      }
    else
      state
    end
  end

  defp maybe_flush(state) do
    if state.state_dirty do
      path = Path.join(state.state_dir, "#{state.node_id}.state")
      tmp_path = path <> ".tmp.#{System.unique_integer([:positive])}"
      payload = serialize_state(state)

      with :ok <- File.mkdir_p(state.state_dir),
           :ok <- File.write(tmp_path, payload, [:binary]),
           :ok <- File.rename(tmp_path, path) do
        %{state | state_dirty: false}
      else
        {:error, reason} ->
          require Logger
          # Do NOT log `path` — the state filename embeds the node_id and
          # the storage root, both path-derived identifiers the project
          # telemetry/privacy guidelines exclude. Reason is enough to
          # diagnose (eenospc, eacces, etc.).
          Logger.warning("cache: state flush failed: reason=#{inspect(reason)}")
          # Best-effort cleanup of orphaned tmp file
          _ = File.rm(tmp_path)
          # Keep state_dirty: true so the next flush tick retries
          state
      end
    else
      state
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Synchronous flush on shutdown to preserve any state since the
    # last periodic flush. Errors here are logged but do not affect
    # shutdown (we're terminating anyway).
    _ = maybe_flush(state)
    :ok
  end

  defp serialize_state(state) do
    protected_hashes = ordered_set_to_list(state.protected) |> Enum.map(& &1.key_hash)

    # Doorkeeper is NOT persisted — see the spec's file format section.
    # It rebuilds organically from post-restart traffic (one delayed CMS
    # increment per previously-known key on first post-restart sighting).
    :erlang.term_to_binary(
      %{
        format_version: 1,
        node_id: state.node_id,
        written_at: System.system_time(:millisecond),
        aging_epoch: state.local_cms.aging_epoch,
        increments_since_reset: state.local_cms.increments_since_reset,
        sketch: Sketch.serialize(state.local_cms),
        protected_hashes: protected_hashes
      },
      [:deterministic]
    )
  end

  defp cleanup_stale_peer_files(state) do
    case File.ls(state.state_dir) do
      {:ok, files} ->
        now = System.system_time(:millisecond)
        own = "#{state.node_id}.state"

        Enum.each(files, fn f ->
          if String.ends_with?(f, ".state") and f != own do
            path = Path.join(state.state_dir, f)
            case File.stat(path, time: :posix) do
              {:ok, %{mtime: mtime}} ->
                age_ms = now - mtime * 1000
                if age_ms > state.state_ttl_ms, do: File.rm(path)

              _ ->
                :ok
            end
          end
        end)

      {:error, _} ->
        :ok
    end

    state
  end
```

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/admission.ex test/image_pipe/cache/file_system/admission_test.exs
git commit -m "Add Admission aging trigger, flush ticker, and cleanup ticker"
```

---

### Task 19: Admission — warm-start from own + peer files

**Files:**
- Modify: `lib/image_pipe/cache/file_system/admission.ex`
- Modify: `test/image_pipe/cache/file_system/admission_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
  test "boot warm-starts from own state file (CMS restored; doorkeeper starts empty)", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    state_dir = Keyword.fetch!(opts, :state_dir)
    File.mkdir_p!(state_dir)

    sketch = Sketch.new(depth: 4, width: 256) |> Sketch.increment("hot-key") |> Sketch.increment("hot-key")

    payload = :erlang.term_to_binary(
      %{
        format_version: 1,
        node_id: "test-node",
        written_at: System.system_time(:millisecond),
        aging_epoch: 0,
        increments_since_reset: 2,
        sketch: Sketch.serialize(sketch),
        protected_hashes: []
      },
      [:deterministic]
    )

    File.write!(Path.join(state_dir, "test-node.state"), payload)

    pid = start_supervised!({Admission, opts})
    state = :sys.get_state(pid)

    assert Sketch.estimate(state.local_cms, "hot-key") >= 1
    # Doorkeeper is intentionally not persisted; it boots empty.
    refute Talan.BloomFilter.member?(state.doorkeeper, "hot-key")
  end

  test "boot merges peer state files into boot_cms", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    state_dir = Keyword.fetch!(opts, :state_dir)
    File.mkdir_p!(state_dir)

    peer_sketch =
      Sketch.new(depth: 4, width: 256)
      |> Sketch.increment("global-hot")
      |> Sketch.increment("global-hot")
      |> Sketch.increment("global-hot")

    peer_payload = :erlang.term_to_binary(
      %{
        format_version: 1,
        node_id: "peer-1",
        written_at: System.system_time(:millisecond),
        aging_epoch: 0,
        increments_since_reset: 3,
        sketch: Sketch.serialize(peer_sketch),
        protected_hashes: []
      },
      [:deterministic]
    )

    File.write!(Path.join(state_dir, "peer-1.state"), peer_payload)

    pid = start_supervised!({Admission, opts})
    state = :sys.get_state(pid)

    assert Sketch.estimate(state.boot_cms, "global-hot") >= 1
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement warm-start in `init/1`**

```elixir
  def init(opts) do
    # ... build initial State struct as before ...
    state = warm_start(state)
    {:ok, state, {:continue, :schedule_tickers}}
  end

  defp warm_start(state) do
    state
    |> load_own_state()
    |> load_peer_state()
  end

  defp load_own_state(state) do
    path = Path.join(state.state_dir, "#{state.node_id}.state")

    case File.read(path) do
      {:ok, binary} ->
        case decode_state_payload(binary, state) do
          {:ok, payload} -> apply_own_state(state, payload)
          {:error, reason} ->
            require Logger
            Logger.warning("Admission: own state file decode failed: #{inspect(reason)}; cold boot")
            state
        end

      {:error, :enoent} ->
        state

      {:error, reason} ->
        require Logger
        Logger.warning("Admission: own state file read failed: #{inspect(reason)}; cold boot")
        state
    end
  end

  defp load_peer_state(state) do
    case File.ls(state.state_dir) do
      {:ok, files} ->
        own = "#{state.node_id}.state"
        now = System.system_time(:millisecond)

        Enum.reduce(files, state, fn f, acc ->
          if String.ends_with?(f, ".state") and f != own and within_ttl?(acc, f, now) do
            merge_peer_file(acc, f)
          else
            acc
          end
        end)

      {:error, _} ->
        state
    end
  end

  defp within_ttl?(state, filename, now_ms) do
    case File.stat(Path.join(state.state_dir, filename), time: :posix) do
      {:ok, %{mtime: mtime}} -> now_ms - mtime * 1000 < state.state_ttl_ms
      _ -> false
    end
  end

  defp merge_peer_file(state, filename) do
    path = Path.join(state.state_dir, filename)

    with {:ok, binary} <- File.read(path),
         {:ok, payload} <- decode_state_payload(binary, state),
         {:ok, peer_sketch} <-
           Sketch.deserialize(payload.sketch,
             depth: state.sketch_depth,
             width: state.sketch_width,
             sample_size: state.aging_sample_size
           ) do
      %{state | boot_cms: Sketch.sum(state.boot_cms, peer_sketch)}
    else
      {:error, reason} ->
        require Logger
        # Path omitted (embeds peer node_id + storage root). Reason only.
        Logger.warning("cache: peer state merge failed: reason=#{inspect(reason)}")
        state
    end
  end

  defp decode_state_payload(binary, _state) do
    try do
      payload = :erlang.binary_to_term(binary, [:safe])
      validate_state_payload(payload)
    rescue
      ArgumentError -> {:error, :decode_failed}
    end
  end

  defp validate_state_payload(%{
         format_version: 1,
         node_id: node_id,
         written_at: written_at,
         aging_epoch: aging_epoch,
         increments_since_reset: increments_since_reset,
         sketch: sketch,
         protected_hashes: protected_hashes
       } = payload)
       when is_binary(node_id) and is_integer(written_at) and
              is_integer(aging_epoch) and aging_epoch >= 0 and
              is_integer(increments_since_reset) and increments_since_reset >= 0 and
              is_binary(sketch) and is_list(protected_hashes) do
    if Enum.all?(protected_hashes, &is_binary/1) do
      {:ok, payload}
    else
      {:error, :invalid_protected_hashes}
    end
  end

  defp validate_state_payload(%{format_version: v}), do: {:error, {:unsupported_format_version, v}}
  defp validate_state_payload(_other), do: {:error, :invalid_shape}

  defp apply_own_state(state, payload) do
    {:ok, sketch} =
      Sketch.deserialize(payload.sketch,
        depth: state.sketch_depth,
        width: state.sketch_width,
        sample_size: state.aging_sample_size
      )
    persisted_protected = Map.get(payload, :protected_hashes, [])

    %{
      state
      | local_cms: sketch,
        # Doorkeeper is intentionally not restored — keep the empty one
        # created at init. See spec's "<node_id>.state file format" for
        # rationale.
        persisted_protected_hashes: persisted_protected
    }
    # protected_hashes restoration into the protected ETS table is handled
    # by the two-pass directory scan in Task 21.
  end
```

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/admission.ex test/image_pipe/cache/file_system/admission_test.exs
git commit -m "Add Admission warm-start from own state and peer state files"
```

---

### Task 20: Admission — background directory scan with conflict resolution

**Files:**
- Modify: `lib/image_pipe/cache/file_system/admission.ex`
- Modify: `lib/image_pipe/cache/file_system.ex` (add `read_descriptor/1`)
- Modify: `test/image_pipe/cache/file_system/admission_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
  test "background scan inserts on-disk entries into probationary", %{registry: registry, tmp_dir: tmp_dir} do
    # Pre-place a .meta file via the existing FileSystem adapter helpers...
    # (omitted for brevity; build a Key, open_sink, write_chunk, commit_sink,
    # all against the unbounded path so the directory exists pre-Admission boot)

    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    # Wait for the scan task to complete; use a sync helper if available
    Admission.await_scan(pid, 5_000)

    state = :sys.get_state(pid)
    assert state.probationary_bytes > 0
  end

  test "scan does not overwrite a key already inserted by runtime traffic", %{registry: registry, tmp_dir: tmp_dir} do
    # Pre-place an entry on disk with descriptor D_disk.
    # Boot Admission and immediately admit a different descriptor D_new for the same key
    # before the scan reaches it. After scan completes, verify the queue holds D_new.

    # (concrete setup omitted; uses fixtures + Process.send to control timing)
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Add `read_descriptor/1` to the FileSystem adapter**

The scan reads meta files off disk and synthesizes admit-time
descriptors. Meta-payload parsing is adapter-owned (it already lives in
`decode_metadata/1` + `validate_metadata/1`), so the descriptor reader
belongs in `file_system.ex`, not in Admission. Admission calls it
qualified (both modules are in the `cache` boundary). It reuses the
existing private meta readers and adds an mtime stat; `key_hash` comes
from the meta filename stem (the canonical name written by
`paths_from_hash/2`):

```elixir
  # In lib/image_pipe/cache/file_system.ex
  @doc false
  @spec read_descriptor(Path.t()) ::
          {:ok, %{key_hash: binary(), size_bytes: non_neg_integer(),
                  body_sha256: binary(), cost_us: non_neg_integer()}, integer()}
          | {:error, term()}
  def read_descriptor(meta_path) do
    with {:ok, meta_binary} <- read_cache_file(meta_path, :metadata),
         {:ok, metadata} <- decode_metadata(meta_binary),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(meta_path, time: :posix) do
      {:ok,
       %{
         key_hash: Path.basename(meta_path, ".meta"),
         size_bytes: metadata.body_byte_size,
         body_sha256: metadata.body_sha256,
         # Pre-Task-10 meta files have no cost_us; default 0 (cold path).
         cost_us: Map.get(metadata, :cost_us, 0)
       }, mtime}
    else
      :miss -> {:error, :enoent}
      {:error, _} = error -> error
    end
  end
```

`read_cache_file/2` returns `:miss` for `:enoent`; normalize that to an
`{:error, _}` so callers (`scan_directory`, `build_descriptor_map`) keep
their two-clause `{:ok, _, _}` / `{:error, _}` match.

- [ ] **Step 4: Implement scan task with batch apply**

```elixir
  @impl true
  def handle_continue(:schedule_tickers, state) do
    # Capture the Admission pid BEFORE spawning. Inside the spawned
    # process, `self()` is the scan's pid — calls would go to the wrong
    # process. `spawn_monitor` gives us an UNLINKED, MONITORED worker: a
    # scan crash does not take Admission down (unlinked), but it delivers
    # a `:DOWN` so we can release `await_scan` waiters instead of hanging
    # (monitored). No Task.Supervisor is used because its name would have
    # to be unique per configured cache root; `spawn_monitor` sidesteps
    # that and the scan is short-lived.
    admission_pid = self()
    {scan_pid, scan_ref} = spawn_monitor(fn -> scan_directory(state, admission_pid) end)
    state = %{state | scan_task: scan_pid, scan_task_ref: scan_ref}

    Process.send_after(self(), :flush, state.flush_interval_ms)
    Process.send_after(self(), :cleanup, state.cleanup_interval_ms)
    Process.send_after(self(), :reconcile, state.reconcile_interval_ms)
    {:noreply, state}
  end

  @doc """
  Block until the background directory scan has reported completion.
  Test/diagnostic helper — production callers never need to wait. Returns
  `:ok` once the scan finishes (or has already finished); the call times
  out normally if the scan exceeds `timeout`.
  """
  @spec await_scan(GenServer.server(), timeout()) :: :ok
  def await_scan(server, timeout \\ 5_000) do
    GenServer.call(server, :await_scan, timeout)
  end

  @impl true
  def handle_call(:await_scan, from, state) do
    if state.scan_complete? do
      {:reply, :ok, state}
    else
      {:noreply, %{state | scan_waiters: [from | state.scan_waiters]}}
    end
  end

  @impl true
  def handle_call(:scan_complete, _from, state) do
    Enum.each(state.scan_waiters, &GenServer.reply(&1, :ok))
    {:reply, :ok, %{state | scan_complete?: true, scan_waiters: []}}
  end

  # The monitored scan process finished. We only act on the failure case:
  # if it died abnormally before sending `:scan_complete`, mark the scan
  # complete anyway and release waiters so `await_scan/2` callers don't
  # block until timeout. A normal exit after `:scan_complete` is a no-op
  # (flag already set). `spawn_monitor` sends no result message, only this
  # `:DOWN`, so there is nothing else to drain.
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{scan_task_ref: ref} = state) do
    if reason != :normal and not state.scan_complete? do
      require Logger
      Logger.warning("cache: directory scan crashed before completion: reason=#{inspect(reason)}")
      Enum.each(state.scan_waiters, &GenServer.reply(&1, :ok))
      {:noreply, %{state | scan_complete?: true, scan_waiters: [], scan_task: nil, scan_task_ref: nil}}
    else
      {:noreply, %{state | scan_task: nil, scan_task_ref: nil}}
    end
  end

  defp scan_directory(state, admission_pid) do
    # Scan the entry directory: <root>/<path_prefix>. Exclude
    # `.cache_state` (where state files live) and any non-meta files.
    entry_root = Path.join(state.root, state.path_prefix)

    # Scan batches carry "entry" maps: the descriptor with `:mtime`
    # merged in. This is the SAME shape Task 21's two-pass scan produces
    # (`build_descriptor_map/1`), so `apply_scan_batch` stays uniform
    # across both tasks — do not switch to `{descriptor, mtime}` tuples.
    entries =
      walk_meta_files(entry_root)
      |> Enum.flat_map(fn meta_path ->
        # `read_descriptor/1` is owned by the adapter — it parses the meta
        # payload format and stats the file. Admission only knows the
        # descriptor shape, not the on-disk meta encoding.
        case ImagePipe.Cache.FileSystem.read_descriptor(meta_path) do
          {:ok, descriptor, mtime} -> [Map.put(descriptor, :mtime, mtime)]
          {:error, _} -> []
        end
      end)

    Enum.chunk_every(entries, 100)
    |> Enum.each(fn chunk ->
      GenServer.call(admission_pid, {:apply_scan_batch, chunk})
    end)

    GenServer.call(admission_pid, :scan_complete)
  end

  defp walk_meta_files(entry_root) do
    # Recursively walk <entry_root>/AB/CD/ for *.meta files. Skip the
    # `.cache_state` subdirectory at the root (a sibling, not a child,
    # but defensively skipped in case path_prefix is empty).
    case File.ls(entry_root) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 == ".cache_state"))
        |> Enum.flat_map(fn entry ->
          path = Path.join(entry_root, entry)

          cond do
            File.dir?(path) -> walk_meta_files(path)
            String.ends_with?(entry, ".meta") -> [path]
            true -> []
          end
        end)

      {:error, _} ->
        []
    end
  end

  @impl true
  def handle_call({:apply_scan_batch, batch}, _from, state) do
    state =
      Enum.reduce(batch, state, fn entry, acc ->
        if already_tracked?(acc, entry.key_hash) do
          # Runtime traffic (hit synthesis, admit) has populated this
          # key already. Its descriptor is fresher than what scan read
          # from disk; skip.
          acc
        else
          insert_scan_descriptor(acc, entry)
        end
      end)

    {:reply, :ok, state}
  end

  # `entry` is a descriptor map with a `:mtime` field merged in. The
  # mtime drove the scan's insertion order (Task 21 Phase B sorts by it);
  # it is not stored in the queue, so we drop it before inserting.
  defp insert_scan_descriptor(state, entry) do
    descriptor = Map.delete(entry, :mtime)
    {pos, state} = next_position(state)
    :ets.insert(state.probationary, {{pos, descriptor.key_hash}, descriptor})
    Map.update!(state, :probationary_bytes, &(&1 + descriptor.size_bytes))
  end
```

Note: `state.path_prefix` must be added to the `State` defstruct (default
empty string) and populated from adapter opts in `init/1`. Two-pass
protected restoration is added in the next task.

- [ ] **Step 5: Run, confirm pass**

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/cache/file_system/admission.ex lib/image_pipe/cache/file_system.ex test/image_pipe/cache/file_system/admission_test.exs
git commit -m "Add background scan with conflict-resolution insert pass"
```

---

### Task 21: Admission — two-pass scan for protected order restoration

**Files:**
- Modify: `lib/image_pipe/cache/file_system/admission.ex`
- Modify: `test/image_pipe/cache/file_system/admission_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
  test "protected entries are restored in LRU-to-MRU order from persisted state", %{registry: registry, tmp_dir: tmp_dir} do
    # Pre-place state file with protected_hashes: ["older_hash", "newer_hash"]
    # Pre-place .meta files for both hashes
    # Boot Admission
    # Verify protected queue order matches LRU→MRU
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Restructure scan to two-pass + add reconciliation**

```elixir
  defp scan_directory(state, admission_pid) do
    entry_root = Path.join(state.root, state.path_prefix)
    descriptor_map = build_descriptor_map(entry_root)

    # Phase A: insert protected entries in persisted LRU→MRU order.
    protected_hashes = state.persisted_protected_hashes
    GenServer.call(admission_pid, {:apply_protected_batch, protected_hashes, descriptor_map})

    # Phase B: insert remaining entries (those not in protected_hashes)
    # in mtime order. Batches of 100 to bound per-call latency.
    protected_set = MapSet.new(protected_hashes)

    remaining =
      descriptor_map
      |> Enum.reject(fn {hash, _entry} -> MapSet.member?(protected_set, hash) end)
      |> Enum.map(fn {_hash, entry} -> entry end)
      |> Enum.sort_by(fn %{mtime: mtime} -> mtime end)

    Enum.chunk_every(remaining, 100)
    |> Enum.each(&GenServer.call(admission_pid, {:apply_scan_batch, &1}))

    # Phase C: post-scan reconciliation. If total bytes ended up over
    # cap (operator lowered cap, previous run wrote past soft cap),
    # evict by LRU until under budget. No score gate — these are
    # already-cached entries with no candidate to compare against.
    GenServer.call(admission_pid, :reconcile_to_cap)

    GenServer.call(admission_pid, :scan_complete)
  end

  defp build_descriptor_map(entry_root) do
    walk_meta_files(entry_root)
    |> Enum.flat_map(fn meta_path ->
      case ImagePipe.Cache.FileSystem.read_descriptor(meta_path) do
        {:ok, descriptor, mtime} ->
          [{descriptor.key_hash, Map.put(descriptor, :mtime, mtime)}]

        {:error, _} ->
          []
      end
    end)
    |> Map.new()
  end

  @impl true
  def handle_call({:apply_protected_batch, hashes, descriptor_map}, _from, state) do
    state =
      Enum.reduce(hashes, state, fn hash, acc ->
        case Map.fetch(descriptor_map, hash) do
          {:ok, entry} ->
            if already_tracked?(acc, hash) do
              acc
            else
              # Drop the scan-only `:mtime` field so queued descriptors
              # have the same shape regardless of which queue they land in.
              descriptor = Map.delete(entry, :mtime)
              {pos, acc} = next_position(acc)
              :ets.insert(acc.protected, {{pos, hash}, descriptor})
              Map.update!(acc, :protected_bytes, &(&1 + descriptor.size_bytes))
            end

          :error ->
            # Persisted protected hash whose meta no longer exists on
            # disk. Skip silently — same-key delete or external sweep.
            acc
        end
      end)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:reconcile_to_cap, _from, state) do
    {:reply, :ok, reconcile_to_cap(state, [])}
  end

  defp reconcile_to_cap(state, evicted_descriptors) do
    total = state.window_bytes + state.probationary_bytes + state.protected_bytes

    cond do
      total <= state.max_size_bytes ->
        # Delete the evicted entries' files. Admission owns deletion here
        # (no request process is in the loop for boot/periodic
        # reconciliation), calling the adapter's `delete_victims/2`
        # in-boundary. See `emit_reconciliation_evictions/2`.
        emit_reconciliation_evictions(state, evicted_descriptors)
        state

      true ->
        # Evict LRU from probationary first, then protected.
        {evicted, state} = evict_one_lru(state)

        case evicted do
          nil ->
            # No more entries to evict but still over cap. Bug or empty
            # cache with impossibly low max_size_bytes; log and stop.
            require Logger
            Logger.warning("cache: reconciliation cannot bring usage under cap")
            emit_reconciliation_evictions(state, evicted_descriptors)
            state

          descriptor ->
            reconcile_to_cap(state, [descriptor | evicted_descriptors])
        end
    end
  end

  defp evict_one_lru(state) do
    cond do
      :ets.info(state.probationary, :size) > 0 ->
        evict_lru_from(state, :probationary)

      :ets.info(state.protected, :size) > 0 ->
        evict_lru_from(state, :protected)

      true ->
        {nil, state}
    end
  end

  defp evict_lru_from(state, queue) do
    table = Map.fetch!(state, queue)
    bytes_field = :"#{queue}_bytes"
    {pos, hash} = :ets.first(table)
    [{_key, descriptor}] = :ets.lookup(table, {pos, hash})
    :ets.delete(table, {pos, hash})
    state = Map.update!(state, bytes_field, &(&1 - descriptor.size_bytes))
    {descriptor, state}
  end

  defp emit_reconciliation_evictions(_state, []), do: :ok
  defp emit_reconciliation_evictions(state, descriptors) do
    # Reconciliation evictions are full evictions: both body and meta
    # files must go. Admission deletes them directly through the adapter's
    # path helper (both modules live in the `cache` boundary). This is the
    # same inline-I/O posture as `maybe_flush/1`; reconciliation batches
    # are small (bounded by recent overshoot), so blocking the GenServer
    # briefly is acceptable.
    victims = Enum.map(descriptors, &full_eviction_victim/1)
    opts = [root: state.root, path_prefix: state.path_prefix]
    ImagePipe.Cache.FileSystem.delete_victims(victims, opts)
    :ok
  end
```

Persisted protected hashes are loaded in `init/1` (Task 19's
`apply_own_state` already populates `state.persisted_protected_hashes`).

**Why `reconcile_to_cap/2` is also reachable outside boot.** The
synchronous admit path bounds overshoot at admission time, but
`same_key_replace/2` (Task 16) swaps a larger body in place **without**
re-running the main gate — a stream of growing same-key re-commits can
push `probationary_bytes + protected_bytes` past the main budget and
never reclaim on its own. A periodic `:reconcile` tick (wired in Task 18
alongside `:flush`/`:cleanup`) calls `reconcile_to_cap/2` to drain that
overshoot by LRU and delete the evicted files. This keeps the soft cap a
*time-bounded* guarantee for same-key growth, consistent with the
in-flight-overshoot model for fresh admissions.

`delete_victims/2` must therefore be a module-public (`@doc false`)
function on the adapter rather than a private helper — see Task 23.

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system/admission.ex test/image_pipe/cache/file_system/admission_test.exs
git commit -m "Restore protected segment in order + reconcile over-cap state on boot"
```

---

## Phase 4: FileSystem adapter integration

### Task 22: FileSystem adapter — `child_spec/1` for bounded mode

**Files:**
- Modify: `lib/image_pipe/cache/file_system.ex`
- Modify: `test/image_pipe/cache/file_system_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
  test "child_spec/1 returns a supervisor spec when max_size_bytes is set", %{tmp_dir: tmp_dir} do
    opts = [root: tmp_dir, max_size_bytes: 10_000_000, node_id: "n1"]
    assert %{id: _, start: _} = FileSystem.child_spec(opts)
  end

  test "no child_spec for unbounded mode" do
    # We expect an explicit indication that unbounded mode doesn't require supervision
    assert FileSystem.child_spec([root: "/tmp"]) == :ignore
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `child_spec/1`**

```elixir
  def child_spec(opts) do
    if Keyword.has_key?(opts, :max_size_bytes) do
      registry_name = registry_name()
      Supervisor.child_spec(
        {Supervisor,
         [
           {Registry, keys: :unique, name: registry_name},
           {ImagePipe.Cache.FileSystem.Admission, Keyword.put(opts, :registry, registry_name)}
         ]},
        id: {__MODULE__, Keyword.fetch!(opts, :root)}
      )
    else
      :ignore
    end
  end

  defp registry_name, do: ImagePipe.Cache.FileSystem.Registry
```

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system.ex test/image_pipe/cache/file_system_test.exs
git commit -m "Add FileSystem.child_spec/1 returning Admission supervisor in bounded mode"
```

---

### Task 22b: Add `paths_from_hash/2` helper

The existing `paths/2` takes a full `%ImagePipe.Cache.Key{}`, but the
bounded-mode victim deletion only knows the key hash. Constructing a
fake `%Key{}` to call `paths/2` is awkward and conflates two things;
extract a small helper.

**Files:**
- Modify: `lib/image_pipe/cache/file_system.ex`
- Modify: `test/image_pipe/cache/file_system_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
  test "paths_from_hash/2 builds the partitioned paths for a given hash", %{tmp_dir: tmp_dir} do
    hash = String.duplicate("a", 64)
    opts = [root: tmp_dir, path_prefix: ""]

    {:ok, paths} = FileSystem.paths_from_hash(hash, opts)

    # First two hex pairs partition the tree (see do_partitions/1).
    assert paths.dir == Path.join([tmp_dir, "aa", "aa"])
    assert paths.meta_path == Path.join([tmp_dir, "aa", "aa", hash <> ".meta"])
    assert paths.hash == hash
    assert paths.root == tmp_dir
  end

  test "paths_from_hash/2 validates hash format" do
    assert {:error, {:invalid_hash, _}} = FileSystem.paths_from_hash("not-a-hash", [root: "/tmp"])
  end

  test "paths_from_hash/2 derives partition dir from the GIVEN hash, not any candidate" do
    # Two different hashes should land in different partitions.
    hash_a = String.duplicate("a", 64)
    hash_b = String.duplicate("b", 64)
    opts = [root: "/tmp", path_prefix: ""]

    {:ok, paths_a} = FileSystem.paths_from_hash(hash_a, opts)
    {:ok, paths_b} = FileSystem.paths_from_hash(hash_b, opts)

    refute paths_a.dir == paths_b.dir
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Refactor `paths/2` to delegate to `paths_from_hash/2`**

```elixir
  @doc false
  def paths(%Key{hash: hash}, opts), do: paths_from_hash(hash, opts)

  @doc false
  def paths_from_hash(hash, opts) when is_binary(hash) and is_list(opts) do
    with {:ok, opts} <- validate_filesystem_options(opts),
         root = Keyword.fetch!(opts, :root),
         path_prefix = Keyword.fetch!(opts, :path_prefix),
         {:ok, {first_partition, second_partition}} <- partitions(hash) do
      dir = Path.join([root, path_prefix, first_partition, second_partition])
      meta_path = Path.join(dir, hash <> ".meta")

      with :ok <- validate_under_root(root, dir) do
        {:ok, %{root: root, dir: dir, meta_path: meta_path, hash: hash}}
      end
    end
  end
```

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system.ex test/image_pipe/cache/file_system_test.exs
git commit -m "Extract paths_from_hash/2 helper for victim path computation"
```

---

### Task 23: FileSystem `commit_sink` — admit/1 integration

**Files:**
- Modify: `lib/image_pipe/cache/file_system.ex`
- Modify: `test/image_pipe/cache/file_system_test.exs`

- [ ] **Step 1: Write failing integration test**

A full end-to-end test: configure adapter with `:max_size_bytes`, start supervisor explicitly via `start_supervised!`, write entries, verify admission decisions.

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement bounded-mode commit_sink**

Rename the existing unbounded body to `legacy_commit/1` and dispatch on
mode. **Accounting must follow the rename, not precede it.** `admit/1`
mutates Admission's in-memory queues (it evicts the chosen victims and
inserts the candidate) the moment it returns `{:admit, victims}`. If we
called `admit` first and the rename then failed, Admission would track a
phantom entry that never landed on disk *and* the victim files would be
orphaned (evicted from the queues but never deleted, because the
short-circuited error path skips `delete_victims`). Renaming first also
gives us the computed `body_sha256` (produced inside
`prepare_sink_commit/1`) that the descriptor needs.

```elixir
  @impl true
  def commit_sink(state, opts) when is_map(state) do
    case lookup_admission(opts) do
      :unbounded ->
        legacy_commit(state)

      {:ok, pid} ->
        commit_bounded(state, pid, opts)

      :unavailable ->
        # Bounded mode but the Admission process is missing. We cannot
        # account for a write, so we MUST NOT leave an untracked entry on
        # disk (it would silently grow the cache past cap). Nothing has
        # been renamed yet, so clean the temp files and fail open.
        require Logger
        Logger.warning("Admission process unavailable in bounded mode; skipping write")
        cleanup_sink_state(state)
        :ok
    end
  end

  # The existing unbounded commit body, unchanged, extracted under a name.
  defp legacy_commit(state) do
    case prepare_sink_commit(state) do
      {:ok, state, body_filename} -> commit_prepared_sink(state, body_filename)
      {:error, reason, state} -> cleanup_sink_state(state); {:error, reason}
    end
  end

  defp commit_bounded(state, pid, opts) do
    # Write to the final location FIRST, then account.
    case prepare_sink_commit(state) do
      {:ok, prepared, body_filename} ->
        case commit_sink_files(prepared, body_filename) do
          :ok ->
            finish_admission(pid, build_descriptor(prepared, body_filename), opts)

          {:error, reason} ->
            # Rename failed: nothing durable to account for. Never call
            # admit. Propagate the error exactly as unbounded mode would
            # (the Sink layer fails open via cache-write telemetry).
            cleanup_sink_state(prepared)
            {:error, reason}
        end

      {:error, reason, prepared} ->
        cleanup_sink_state(prepared)
        {:error, reason}
    end
  end

  defp finish_admission(pid, descriptor, opts) do
    case ImagePipe.Cache.FileSystem.Admission.admit(pid, descriptor) do
      {:admit, victims} ->
        delete_victims(victims, opts)
        :ok

      {:reject, _reason} ->
        # Admission declined to keep the entry. It was never inserted into
        # the queues (reject mutates nothing), so the only cleanup is the
        # bytes we just wrote. Delete both body and meta so the on-disk
        # state stays consistent with Admission's accounting. The body was
        # already streamed to a temp file during write_chunk, so this
        # costs only two extra renames vs. the unbounded path — the
        # doorkeeper's "don't retain cold entries" property is preserved
        # because the files are removed immediately.
        delete_victims([reject_victim(descriptor)], opts)
        :ok
    end
  end

  # Build the same full-eviction victim shape `delete_victims/2` consumes
  # for a descriptor whose write must be undone.
  defp reject_victim(descriptor) do
    %{
      key_hash: descriptor.key_hash,
      body_sha256: descriptor.body_sha256,
      size_bytes: descriptor.size_bytes,
      delete_body?: true,
      delete_meta?: true
    }
  end

  # `prepare_sink_commit/1` encodes `body_sha256` into `body_filename`
  # (`"<hash>.<sha>.body"`); recover it rather than recomputing the digest.
  defp build_descriptor(prepared, body_filename) do
    {:ok, body_sha256} = body_sha256_from_filename(body_filename)

    %{
      key_hash: prepared.paths.hash,
      size_bytes: prepared.size,
      body_sha256: body_sha256,
      cost_us: prepared.metadata.cost_us
    }
  end

  defp lookup_admission(opts) do
    if Keyword.has_key?(opts, :max_size_bytes) do
      key = {Keyword.fetch!(opts, :root), Keyword.fetch!(opts, :node_id)}
      case Registry.lookup(ImagePipe.Cache.FileSystem.Registry, key) do
        [{pid, _}] -> {:ok, pid}
        [] -> :unavailable
      end
    else
      :unbounded
    end
  end

  # Module-public (not private): the Admission process calls this directly
  # during periodic/boot reconciliation. Both modules are in the `cache`
  # boundary, so this is an in-boundary call, not a public API surface.
  @doc false
  def delete_victims([], _opts), do: :ok

  def delete_victims(victims, opts) do
    Enum.each(victims, fn victim ->
      with {:ok, victim_paths} <- paths_from_hash(victim.key_hash, opts) do
        if victim.delete_body? do
          body_path =
            Path.join(victim_paths.dir, "#{victim.key_hash}.#{victim.body_sha256}.body")
          rm_tolerant(body_path)
        end

        if victim.delete_meta? do
          rm_tolerant(victim_paths.meta_path)
        end
      end
    end)
  end

  defp rm_tolerant(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} ->
        require Logger
        # Path omitted: victim body/meta filenames embed the cache key
        # hash (a cache-adapter internal). Log the reason only.
        Logger.warning("cache: victim delete failed: reason=#{inspect(reason)}")
        :ok
    end
  end
```

This task also depends on the new `paths_from_hash/2` helper (added in
Task 22b). `build_descriptor/2` reads `key_hash`/`size_bytes`/`cost_us`
from the prepared sink state and recovers `body_sha256` from the
committed `body_filename`.

**Note on the `:unavailable` branch:** This is the fail-CLOSED case per
spec — we never write entries the Admission process can't account for,
because doing so silently grows the bounded cache past cap. The lazy
lookup itself remains fail-open (no boot crash on missing process); the
*commit* fails closed when bounded mode is configured but Admission
isn't running.

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system.ex test/image_pipe/cache/file_system_test.exs
git commit -m "Integrate Admission into FileSystem.commit_sink for bounded mode"
```

---

### Task 24: FileSystem `get/2` — hit cast

**Files:**
- Modify: `lib/image_pipe/cache/file_system.ex`
- Modify: `test/image_pipe/cache/file_system_test.exs`

- [ ] **Step 1: Write failing test**

```elixir
  test "get/2 casts a hit descriptor to Admission on successful hit (bounded mode)", %{tmp_dir: tmp_dir} do
    # Setup bounded mode with a small cache, place an entry via commit_sink,
    # perform a get/2, then verify Admission's state shows the entry tracked
    # (synthesized into probationary via the hit-with-descriptor cast).
    # The descriptor must include size_bytes, body_sha256, and cost_us so
    # cold-boot hit synthesis works.
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement hit cast with descriptor**

`get/2` already computes `paths` and delegates to `read_entry/1`. Make
`read_entry/1` surface the parsed meta map alongside the entry
(`{:hit, entry, meta}`), then cast the hit descriptor from `get/2` and
strip the meta back off so the public contract is unchanged:

```elixir
  @impl true
  def get(%Key{} = key, opts) when is_list(opts) do
    case paths(key, opts) do
      {:ok, paths} ->
        case read_entry(paths) do
          {:hit, entry, meta} ->
            # read_entry already parsed/validated the meta payload; reuse
            # its fields rather than re-reading the file.
            maybe_cast_hit(opts, %{
              key_hash: key.hash,
              size_bytes: meta.body_byte_size,
              body_sha256: meta.body_sha256,
              cost_us: Map.get(meta, :cost_us, 0)
            })
            {:hit, entry}

          other ->
            other
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_cast_hit(opts, descriptor) do
    case lookup_admission(opts) do
      {:ok, pid} -> ImagePipe.Cache.FileSystem.Admission.hit(pid, descriptor)
      _ -> :ok
    end
  end
```

`read_entry/1` already binds the validated `metadata` map in its `with`
chain; change its success return from `{:hit, %Entry{...}}` to
`{:hit, %Entry{...}, metadata}`. This is an internal-only change
(`read_entry/1` is private); the public `get/2` still returns
`{:hit, entry}`. `:miss` and `{:error, _}` returns are untouched, so the
`other -> other` arm forwards them as before.

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system.ex test/image_pipe/cache/file_system_test.exs
git commit -m "Cast hit to Admission on FileSystem.get/2 success in bounded mode"
```

---

## Phase 5: Config + telemetry

### Task 25: Config schema extension

**Files:**
- Modify: `lib/image_pipe/cache.ex` (or the FileSystem adapter's `validate_options/1`)
- Modify: `test/image_pipe/cache/file_system_test.exs`

- [ ] **Step 1: Write failing tests**

```elixir
  test "rejects max_size_bytes: 0" do
    assert {:error, _} = FileSystem.validate_options([root: "/tmp", max_size_bytes: 0])
  end

  test "rejects negative max_size_bytes" do
    assert {:error, _} = FileSystem.validate_options([root: "/tmp", max_size_bytes: -1])
  end

  test "rejects bounded options without max_size_bytes" do
    assert {:error, _} = FileSystem.validate_options([root: "/tmp", window_ratio: 0.5])
  end

  test "accepts a complete bounded config" do
    assert {:ok, _opts} =
             FileSystem.validate_options([
               root: "/tmp",
               max_size_bytes: 100_000_000,
               node_id: "n1"
             ])
  end

  test "derives sketch_width and doorkeeper_cardinality from max_size_bytes" do
    {:ok, opts} = FileSystem.validate_options([root: "/tmp", max_size_bytes: 10_000_000_000, node_id: "n1"])
    assert opts[:sketch_width] == 400_000
    assert opts[:doorkeeper_cardinality] == 800_000
    assert opts[:doorkeeper_fpr] == 0.01
    assert opts[:eviction_victim_limit] == 64
    # aging_sample_size = max(81_920, 10_000_000_000 ÷ 5_000) = 2_000_000.
    # Independent of sketch_width's accuracy derivation.
    assert opts[:aging_sample_size] == 2_000_000
    assert opts[:reconcile_interval] == 60
  end

  test "aging_sample_size does not change when sketch_width is overridden" do
    {:ok, opts} =
      FileSystem.validate_options([
        root: "/tmp",
        max_size_bytes: 10_000_000_000,
        node_id: "n1",
        sketch_width: 16_384
      ])

    # Overriding width for accuracy must not move the aging cadence.
    assert opts[:sketch_width] == 16_384
    assert opts[:aging_sample_size] == 2_000_000
  end

  test "accepts custom :eviction_victim_limit" do
    {:ok, opts} =
      FileSystem.validate_options([
        root: "/tmp",
        max_size_bytes: 100_000_000,
        node_id: "n1",
        eviction_victim_limit: 32
      ])

    assert opts[:eviction_victim_limit] == 32
  end

  test "rejects non-positive :eviction_victim_limit" do
    assert {:error, _} =
             FileSystem.validate_options([
               root: "/tmp",
               max_size_bytes: 100_000_000,
               node_id: "n1",
               eviction_victim_limit: 0
             ])
  end
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Extend `validate_options/1` with NimbleOptions schema**

Add new bounded option keys to `@option_keys` and a new schema entry.
`:max_size_bytes` is the opt-in switch: when absent, the adapter stays
unbounded and **none** of the other bounded options (including
`:node_id`) may be required — existing unbounded configs must keep
validating. "Required" below means *required once `:max_size_bytes` is
present*; enforce it in the cross-key post-check, not the per-key
NimbleOptions schema.

Bounded options to support:

- `:max_size_bytes` (the opt-in switch; positive integer; absent ⇒ unbounded)
- `:node_id` (required when bounded; binary)
- `:window_ratio` (default 0.01, float in [0, 1])
- `:sketch_depth` (default 4, positive integer)
- `:sketch_width` (default `max(4096, max_size_bytes ÷ 25_000)`, positive integer)
- `:aging_sample_size` (default `max(81_920, max_size_bytes ÷ 5_000)`, positive integer) — CMS increments between aging passes. **Decoupled from `:sketch_width`**: width tunes counter accuracy, this tunes how fast frequencies decay. Derived from estimated item cardinality (`max_size_bytes ÷ 50_000` ≈ items) × 10, floor `81_920` ≈ 8192 items × 10.
- `:doorkeeper_cardinality` (default `max(8192, max_size_bytes ÷ 12_500)`, positive integer)
- `:doorkeeper_fpr` (default 0.01, float in (0, 1))
- `:flush_interval` (default 30, positive integer, seconds)
- `:cleanup_interval` (default 3600, positive integer, seconds)
- `:reconcile_interval` (default 60, positive integer, seconds) — periodic over-cap reconciliation cadence; drains same-key-growth overshoot.
- `:state_ttl` (default 604_800, positive integer, seconds)
- `:state_dir` (default `<root>/.cache_state`, binary)
- `:eviction_victim_limit` (default 64, positive integer)

Implement derived defaults and cross-validation as a post-check function (NimbleOptions doesn't natively support cross-key validation, so do it after the per-key validation).

The adapter passes `:aging_sample_size` to `Admission` as the `Sketch`
`:sample_size`, and `:reconcile_interval` (×1000) as `:reconcile_interval_ms`.

- [ ] **Step 4: Run, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/cache/file_system.ex test/image_pipe/cache/file_system_test.exs
git commit -m "Extend FileSystem config schema with bounded-mode options"
```

---

### Task 26: Telemetry events

**Files:**
- Modify: `lib/image_pipe/cache/file_system/admission.ex` (emit events)
- Create: `test/image_pipe/cache/file_system/admission_telemetry_test.exs`

Add `:telemetry.span/3`-style events using existing `ImagePipe.Telemetry` helpers:

- `[..., :cache, :admission, :start/:stop]` (per the spec)
- `[..., :cache, :eviction, :stop]`
- `[..., :cache, :warm_start, :start/:stop]`
- `[..., :cache, :flush, :stop]`
- `[..., :cache, :cleanup, :stop]`
- New `cache: :admission_rejected` value for the existing `[..., :cache, :stage, ...]` event

- [ ] **Step 1: Write test attaching to events**
- [ ] **Step 2: Run, confirm failure**
- [ ] **Step 3: Emit events from Admission**
- [ ] **Step 4: Run, confirm pass**
- [ ] **Step 5: Commit**

---

## Phase 6: Integration and edge-case tests

### Task 27: End-to-end bounded mode happy path

**Files:**
- Create: `test/image_pipe/cache/file_system_bounded_test.exs`

Full integration: configure bounded adapter, start supervisor, run 1.5× cap worth of entries through the full `Cache.lookup` + `Sink` + `commit_sink` flow, assert evicted bodies are gone, total disk usage within soft-cap bounds.

- [ ] **Step 1: Write test cycling entries through the adapter**
- [ ] **Step 2: Run, confirm pass** (this test exercises code from previous tasks; should pass once code is complete)
- [ ] **Step 3: Commit**

---

### Task 28: Failure and edge-case tests

**Files:**
- Modify: `test/image_pipe/cache/file_system_bounded_test.exs`

Add tests for:
- Rename failure post-admission (stub `File.rename/2` via `Mox` or test helper)
- Meta present, body missing
- Body present, meta missing
- Corrupt own state file
- Scan racing with commits for the same key
- Duplicate commit for same key with new body_sha256 → old body deleted
- Restart after failed victim delete (orphan body lingers, accounting reconciles via boot scan)
- Tiny legal caps (1024)
- `:max_size_bytes: 0` rejected at validation
- `:window_ratio: 0` disables the window

- [ ] **Step 1: Write each test**
- [ ] **Step 2: Run, confirm pass**
- [ ] **Step 3: Commit**

---

### Task 29: Cross-node warm-start test

**Files:**
- Modify: `test/image_pipe/cache/file_system_bounded_test.exs`

- [ ] **Step 1: Write test**

Pre-place two `<node_id>.state` files in `<state_dir>`, boot Admission, assert merged frequency reflects both via `:sys.get_state/1`.

- [ ] **Step 2: Run, confirm pass**
- [ ] **Step 3: Commit**

---

### Task 30: Soft-cap invariant property test

**Files:**
- Create: `test/image_pipe/cache/file_system_bounded_property_test.exs`

- [ ] **Step 1: Write the property test**

```elixir
defmodule ImagePipe.Cache.FileSystem.BoundedPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ImagePipe.Cache.FileSystem.Admission

  @tag :tmp_dir
  property "Admission-tracked bytes stay within cap + sum of in-flight after any admission sequence" do
    check all descriptors <- list_of(descriptor_generator(), min_length: 0, max_length: 50),
              max_runs: 50 do
      tmp = create_tmp_dir()
      registry = :"#{__MODULE__}.#{System.unique_integer([:positive])}.Registry"
      start_supervised!({Registry, keys: :unique, name: registry})

      opts = [
        registry: registry,
        root: tmp,
        node_id: "prop-node",
        state_dir: Path.join(tmp, ".cache_state"),
        max_size_bytes: 100_000,
        window_ratio: 0.01,
        sketch_depth: 4,
        sketch_width: 64,
        doorkeeper_cardinality: 1024,
        doorkeeper_fpr: 0.01,
        flush_interval_ms: 60_000,  # don't tick during the test
        cleanup_interval_ms: 60_000
      ]

      pid = start_supervised!({Admission, opts})

      Enum.each(descriptors, fn descriptor ->
        # Synchronous admit means no in-flight; tracked bytes stay <= cap.
        Admission.admit(pid, descriptor)
      end)

      state = :sys.get_state(pid)
      tracked = state.window_bytes + state.probationary_bytes + state.protected_bytes
      assert tracked <= 100_000, "Tracked bytes #{tracked} exceeded cap 100_000"
    end
  end

  defp descriptor_generator do
    gen all key <- string(:alphanumeric, min_length: 4, max_length: 16),
            size <- integer(100..50_000),
            cost <- integer(0..100_000) do
      %{
        key_hash: key,
        size_bytes: size,
        body_sha256: "sha-#{key}",
        cost_us: cost
      }
    end
  end

  defp create_tmp_dir do
    tmp = Path.join(System.tmp_dir!(), "bounded_prop_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit_cleanup(tmp)
    tmp
  end

  defp on_exit_cleanup(path) do
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
  end
end
```

- [ ] **Step 2: Run, confirm pass**

```bash
mise exec -- mix test test/image_pipe/cache/file_system_bounded_property_test.exs
```

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/cache/file_system_bounded_property_test.exs
git commit -m "Add soft-cap invariant property test"
```

---

### Task 31: Architecture boundary tests

**Files:**
- Modify: `test/image_pipe/architecture_boundary_test.exs`

**Why not a module-existence test:** Do not assert the new modules exist (`Code.ensure_loaded/1`, `function_exported?/3`, or matching `Atom.to_string(module)` against a `ImagePipe.Cache.FileSystem.*` regex). The project guidelines explicitly reject name- and existence-policing tests, and such an assertion is circular — it only re-states the module list the test itself hardcodes. The real contract worth enforcing is the *dependency direction*: bounded-mode code lives inside the `ImagePipe.Cache` boundary, so it must never reach up into `Request`, `Source`, `Response`, or `Parser`. Enforce that with the same source-scanning approach the rest of this file already uses (`imgproxy_parser_references`, `response delivery stays unaware ...`).

Two layers already cover most of this for free:
- The existing **"cache boundary declaration avoids post-fetch transform state dependencies"** test (`assert_boundary_deps(cache, [...])`) uses exact equality, so any new cross-boundary `deps:` entry in `lib/image_pipe/cache.ex` fails it automatically. No change needed there.
- `Boundary` itself rejects undeclared cross-boundary calls at compile time.

The new test adds a focused source-scan over the bounded-mode files specifically, so an accidental `ImagePipe.Request.*` / `ImagePipe.Source.*` / `ImagePipe.Response.*` / `ImagePipe.Parser.*` reference fails loudly with a file:line even if `Boundary` config drifts.

- [ ] **Step 1: Add a boundary source-scan for bounded-mode cache files**

```elixir
  test "bounded-mode FileSystem cache code stays within the cache boundary" do
    forbidden_terms = [
      "ImagePipe.Request",
      "ImagePipe.Source",
      "ImagePipe.Response",
      "ImagePipe.Parser"
    ]

    cache_filesystem_sources =
      "lib/image_pipe/cache/file_system/**/*.ex"
      |> Path.wildcard()
      |> Map.new(fn file -> {file, File.read!(file)} end)

    violations =
      for {file, source} <- cache_filesystem_sources,
          {line, number} <- source |> String.split("\n") |> Enum.with_index(1),
          term <- forbidden_terms,
          String.contains?(line, term) do
        "#{file}:#{number} must not depend on #{term}; " <>
          "bounded-mode cache code stays within the ImagePipe.Cache boundary"
      end

    assert violations == []
  end
```

The wildcard `lib/image_pipe/cache/file_system/**/*.ex` matches the new submodule files (`sketch.ex`, `policy.ex`, `admission.ex`) without sweeping in `lib/image_pipe/cache/file_system.ex`, which is already exercised by the cache-boundary declaration test. `Cache` is allowed to depend on `Plan`, `Output`, and transform material, so those namespaces are deliberately absent from `forbidden_terms`.

- [ ] **Step 2: Run, confirm pass**
- [ ] **Step 3: Commit**

---

## Phase 7: Documentation

### Task 32: Update `docs/cache.md`

**Files:**
- Modify: `docs/cache.md`

Add a "Bounded mode" section explaining:
- When to use it (`:max_size_bytes` set)
- Required `:node_id` (and the StatefulSet-ordinal recommendation)
- Configuration options table
- Supervision-tree placement (cache before endpoint)
- Soft-cap semantics + boot reconciliation
- Multi-node warm-start behavior (read peer state files)
- New telemetry events
- Known V1 limitations (orphan body files, same-key race, single-process serialization)

- [ ] **Step 1: Write the section**
- [ ] **Step 2: Run docs check if any (e.g., `mise exec -- mix docs`)**
- [ ] **Step 3: Commit**

```bash
git add docs/cache.md
git commit -m "Document bounded-mode FileSystem cache in docs/cache.md"
```

---

## Verification before merge

- [ ] Run full test suite: `mise exec -- mix test`
- [ ] Run with warnings-as-errors: `mise exec -- mix compile --warnings-as-errors`
- [ ] Run Credo strict: `mise exec -- mix credo --strict`
- [ ] Confirm unbounded-mode existing tests still pass unchanged
- [ ] Confirm architecture boundary tests pass
