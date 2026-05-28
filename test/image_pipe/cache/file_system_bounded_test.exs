defmodule ImagePipe.Cache.FileSystemBoundedTest do
  # async: false — the bounded supervision tree registers a Registry under the
  # global name ImagePipe.Cache.FileSystem.Registry (see FileSystem.child_spec/1
  # and lookup_admission/1). Two concurrently-booted bounded trees would clash on
  # that name, so every test in this module runs serially.
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Key

  @node_id "bounded-node"

  defp key(hash \\ String.duplicate("a", 64)) do
    %Key{
      hash: hash,
      data: [schema_version: 1],
      serialized_data: :erlang.term_to_binary([schema_version: 1], [:deterministic])
    }
  end

  defp entry(body) do
    %Entry{
      body: body,
      content_type: "image/webp",
      headers: [{"vary", "Accept"}],
      created_at: ~U[2026-04-29 10:15:00Z]
    }
  end

  defp entry_metadata(overrides) do
    struct!(
      ImagePipe.Cache.Entry.Metadata,
      Keyword.merge(
        [
          content_type: "image/webp",
          headers: [{"vary", "Accept"}],
          created_at: ~U[2026-04-29 10:15:00Z],
          output_format: :webp
        ],
        overrides
      )
    )
  end

  # Mirror admission_test.exs base_opts/1 so Admission boots without Task 25's
  # config-derived defaults. The caller supplies :root and :max_size_bytes.
  defp bounded_opts(root, overrides) do
    Keyword.merge(
      [
        root: root,
        node_id: @node_id,
        state_dir: Path.join(root, ".cache_state"),
        max_size_bytes: overrides[:max_size_bytes] || 1_000_000,
        window_ratio: 0.01,
        sketch_depth: 4,
        sketch_width: 256,
        doorkeeper_cardinality: 1024,
        doorkeeper_fpr: 0.01
      ],
      Keyword.drop(overrides, [:max_size_bytes])
    )
  end

  defp put_entry(cache_key, %Entry{} = e, opts) do
    metadata =
      entry_metadata(
        content_type: e.content_type,
        headers: e.headers,
        created_at: e.created_at
      )

    with {:ok, state} <- FileSystem.open_sink(cache_key, metadata, opts),
         {:ok, state} <- FileSystem.write_chunk(state, e.body, opts) do
      FileSystem.commit_sink(state, opts)
    end
  end

  defp admission_pid(root) do
    [{pid, _}] = Registry.lookup(ImagePipe.Cache.FileSystem.Registry, {root, @node_id})
    pid
  end

  defp body_path(root, cache_key, body) do
    sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    Path.join([root, "aa", "aa", "#{cache_key.hash}.#{sha}.body"])
  end

  defp meta_path(root, cache_key) do
    Path.join([root, "aa", "aa", "#{cache_key.hash}.meta"])
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "image_pipe_fs_bounded_#{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    Map.put(context, :root, root)
  end

  test "admitted entry is written and tracked by Admission", %{root: root} do
    opts = bounded_opts(root, max_size_bytes: 1_000_000)
    start_supervised!(FileSystem.child_spec(opts))

    cache_key = key()
    assert :ok = put_entry(cache_key, entry("encoded image"), opts)

    # Files landed on disk.
    assert File.exists?(meta_path(root, cache_key))
    assert File.exists?(body_path(root, cache_key, "encoded image"))

    # Admission tracked the candidate (probationary or window bytes > 0).
    state = :sys.get_state(admission_pid(root))
    assert state.window_bytes + state.probationary_bytes + state.protected_bytes > 0

    assert {:hit, hit} = FileSystem.get(cache_key, opts)
    assert hit.body == "encoded image"
  end

  test "rejected (over-cap) entry deletes the written body and meta", %{root: root} do
    # max_size_bytes smaller than the entry forces {:reject, :over_cap}.
    opts = bounded_opts(root, max_size_bytes: 4)
    start_supervised!(FileSystem.child_spec(opts))

    cache_key = key()
    assert :ok = put_entry(cache_key, entry("this body is way over the cap"), opts)

    # Both body and meta were cleaned up; nothing untracked remains.
    refute File.exists?(meta_path(root, cache_key))
    refute File.exists?(body_path(root, cache_key, "this body is way over the cap"))

    # No accounting for the rejected entry.
    state = :sys.get_state(admission_pid(root))
    assert state.window_bytes + state.probationary_bytes + state.protected_bytes == 0

    assert FileSystem.get(cache_key, opts) == :miss
  end

  test "get/2 casts a hit descriptor to Admission, synthesizing tracking", %{root: root} do
    bounded = bounded_opts(root, max_size_bytes: 1_000_000)
    start_supervised!(FileSystem.child_spec(bounded))

    cache_key = key()

    # Place the entry on disk WITHOUT going through bounded admit, so Admission
    # is not yet tracking it (mirrors a cold-boot hit before the scan reaches
    # the key). Unbounded opts skip the admit path entirely.
    unbounded = [root: root]
    assert :ok = put_entry(cache_key, entry("encoded image"), unbounded)

    pid = admission_pid(root)
    assert :sys.get_state(pid).probationary_bytes == 0

    # A bounded get hits and casts the descriptor to Admission.
    assert {:hit, hit} = FileSystem.get(cache_key, bounded)
    assert hit.body == "encoded image"

    # Flush the async hit cast, then assert the synthesized probationary entry.
    _ = :sys.get_state(pid)
    assert :sys.get_state(pid).probationary_bytes == byte_size("encoded image")
  end

  test "bounded mode with no Admission process fails closed (skips write)", %{root: root} do
    # Bounded opts but no supervision tree started: lookup_admission/1 returns
    # :unavailable, so commit_sink must NOT leave an untracked entry on disk.
    opts = bounded_opts(root, max_size_bytes: 1_000_000)

    cache_key = key()
    assert :ok = put_entry(cache_key, entry("encoded image"), opts)

    refute File.exists?(meta_path(root, cache_key))
    refute File.exists?(body_path(root, cache_key, "encoded image"))
    assert FileSystem.get(cache_key, opts) == :miss
  end
end
