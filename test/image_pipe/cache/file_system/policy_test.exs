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
