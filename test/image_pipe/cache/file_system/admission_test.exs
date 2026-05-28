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

  test "same-key re-commit returns body-only victim when body_sha256 differs", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    {:admit, []} =
      Admission.admit(pid, %{key_hash: "k", size_bytes: 1_000, body_sha256: "sha_old", cost_us: 1_000})

    {:admit, victims} =
      Admission.admit(pid, %{key_hash: "k", size_bytes: 1_500, body_sha256: "sha_new", cost_us: 2_000})

    # The victim must point at the OLD body (for deletion) but NOT
    # delete the meta — the meta path is identical for old and new
    # entries, and the adapter has just renamed the new meta into
    # place. Deleting the meta would destroy the new entry.
    assert [
             %{
               key_hash: "k",
               body_sha256: "sha_old",
               delete_body?: true,
               delete_meta?: false
             }
           ] = victims
  end

  test "same-key re-commit emits NO victim when body_sha256 matches", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir)
    pid = start_supervised!({Admission, opts})

    {:admit, []} =
      Admission.admit(pid, %{key_hash: "k", size_bytes: 1_000, body_sha256: "same_sha", cost_us: 1_000})

    {:admit, victims} =
      Admission.admit(pid, %{key_hash: "k", size_bytes: 1_000, body_sha256: "same_sha", cost_us: 1_500})

    # Content-identical rewrite: nothing to delete (the body file path
    # is the same as the just-renamed candidate body).
    assert victims == []
  end

  test "same-key replacement rejected when new size exceeds max_size_bytes", %{registry: registry, tmp_dir: tmp_dir} do
    opts = base_opts(registry: registry, tmp_dir: tmp_dir, max_size_bytes: 10_000)
    pid = start_supervised!({Admission, opts})

    {:admit, []} =
      Admission.admit(pid, %{key_hash: "k", size_bytes: 1_000, body_sha256: "sa", cost_us: 1_000})

    assert {:reject, :over_cap} =
             Admission.admit(pid, %{key_hash: "k", size_bytes: 20_000, body_sha256: "sb", cost_us: 1_000})

    state = :sys.get_state(pid)
    # Old entry still tracked
    assert in_queue?(state.window, "k") or in_queue?(state.probationary, "k") or
             in_queue?(state.protected, "k")
  end

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
