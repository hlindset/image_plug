defmodule ImagePipe.Cache.FileSystem.AdmissionTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Sketch

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

  test "start_link registers the process under {root, node_id}", %{
    registry: registry,
    tmp_dir: tmp_dir
  } do
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

  test "hit/2 marks the key in doorkeeper on first sighting, increments CMS on second",
       %{registry: registry, tmp_dir: tmp_dir} do
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

  test "hit/2 on untracked key synthesizes a probationary entry from the descriptor",
       %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    descriptor = %{key_hash: "cold", size_bytes: 5_000, body_sha256: "s", cost_us: 1_000}
    Admission.hit(pid, descriptor)
    state = :sys.get_state(pid)

    assert in_queue?(state.probationary, "cold")
    assert state.probationary_bytes == 5_000
  end

  test "admit/2 inserts a candidate at window MRU when window has room",
       %{registry: registry, tmp_dir: tmp_dir} do
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

  test "admit/2 hard-rejects candidates larger than max_size_bytes",
       %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    descriptor = %{
      key_hash: "huge",
      # > 1_000_000 cap
      size_bytes: 10_000_000,
      body_sha256: "sha",
      cost_us: 1_000
    }

    assert {:reject, :over_cap} = Admission.admit(pid, descriptor)
  end

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
    # "b" and "c"
    assert state.window_bytes == 10_000
    # "a" moved into main
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

  # Test-local introspection helper: reads the GenServer's :protected ETS
  # queue tables by key_hash. Admission's own in_queue?/2 is private.
  defp in_queue?(table, key_hash), do: :ets.match_object(table, {{:_, key_hash}, :_}) != []
end
