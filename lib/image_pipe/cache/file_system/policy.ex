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
