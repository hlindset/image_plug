defmodule ImagePlug.Cache.FileSystemTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.FileSystem
  alias ImagePlug.Cache.Key

  defp key(hash \\ String.duplicate("a", 64)) do
    %Key{
      hash: hash,
      material: [schema_version: 1],
      serialized_material: :erlang.term_to_binary([schema_version: 1], [:deterministic])
    }
  end

  defp entry(body \\ "encoded image") do
    %Entry{
      body: body,
      content_type: "image/webp",
      headers: [{"vary", "Accept"}],
      created_at: ~U[2026-04-29 10:15:00Z]
    }
  end

  defp body_sha256(body) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
  end

  defp body_filename(cache_key, body), do: "#{cache_key.hash}.#{body_sha256(body)}.body"

  defp metadata(cache_key, body, overrides \\ []) do
    Map.merge(
      %{
        metadata_version: 1,
        content_type: "image/webp",
        headers: [],
        created_at: "2026-04-29T10:15:00Z",
        body_byte_size: byte_size(body),
        body_sha256: body_sha256(body),
        body_filename: body_filename(cache_key, body)
      },
      Map.new(overrides)
    )
  end

  defp root(context) do
    Path.join(System.tmp_dir!(), "image_plug_fs_cache_#{context.test}")
  end

  setup context do
    root = root(context)
    File.rm_rf!(root)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "requires an absolute root" do
    assert FileSystem.get(key(), []) == {:error, {:missing_required_option, :root}}

    assert FileSystem.get(key(), root: "relative/cache") ==
             {:error, {:invalid_root, "relative/cache"}}

    assert FileSystem.validate_options([]) == {:error, {:missing_required_option, :root}}

    assert FileSystem.validate_options(root: "relative/cache") ==
             {:error, {:invalid_root, "relative/cache"}}
  end

  test "rejects traversal-shaped path prefixes", %{root: root} do
    assert FileSystem.get(key(), root: root, path_prefix: "../outside") ==
             {:error, {:invalid_path_prefix, "../outside"}}

    assert FileSystem.get(key(), root: root, path_prefix: "/absolute") ==
             {:error, {:invalid_path_prefix, "/absolute"}}

    assert FileSystem.get(key(), root: root, path_prefix: "processed/./images") ==
             {:error, {:invalid_path_prefix, "processed/./images"}}

    assert FileSystem.get(key(), root: root, path_prefix: "processed//images") ==
             {:error, {:invalid_path_prefix, "processed//images"}}

    assert FileSystem.get(key(), root: root, path_prefix: "~/cache") ==
             {:error, {:invalid_path_prefix, "~/cache"}}

    assert FileSystem.get(key(), root: root, path_prefix: "processed\\..\\outside") ==
             {:error, {:invalid_path_prefix, "processed\\..\\outside"}}

    assert FileSystem.validate_options(root: root, path_prefix: "../outside") ==
             {:error, {:invalid_path_prefix, "../outside"}}
  end

  test "rejects unknown filesystem adapter options", %{root: root} do
    assert FileSystem.validate_options(root: root, path_prefx: "processed") ==
             {:error, {:unknown_options, [:path_prefx]}}

    assert FileSystem.validate_options(root: root, fail_on_cache_error: true) == :ok
  end

  test "accepts filesystem root as cache root" do
    assert FileSystem.get(key(), root: "/") == :miss
  end

  test "rejects cache paths that resolve outside the root through symlinks", %{root: root} do
    outside_root = root <> "_outside"
    File.rm_rf!(outside_root)
    File.mkdir_p!(outside_root)
    on_exit(fn -> File.rm_rf!(outside_root) end)

    File.ln_s!(outside_root, Path.join(root, "aa"))

    assert FileSystem.get(key("aabb" <> String.duplicate("1", 60)), root: root) ==
             {:error, {:path_outside_root, Path.join([root, "aa", "bb"])}}
  end

  test "rejects invalid hashes before path construction", %{root: root} do
    too_short_hash = String.duplicate("a", 63)
    non_hex_hash = String.duplicate("g", 64)
    path_shaped_hash = "abcd/" <> String.duplicate("a", 59)

    assert FileSystem.get(key(too_short_hash), root: root) ==
             {:error, {:invalid_hash, too_short_hash}}

    assert FileSystem.get(key(non_hex_hash), root: root) ==
             {:error, {:invalid_hash, non_hex_hash}}

    assert FileSystem.get(key(path_shaped_hash), root: root) ==
             {:error, {:invalid_hash, path_shaped_hash}}
  end

  test "writes and reads body and metadata under hash-partitioned paths", %{root: root} do
    cache_key = key("abcdef" <> String.duplicate("1", 58))

    assert FileSystem.put(cache_key, entry(), root: root, path_prefix: "processed") == :ok
    assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root, path_prefix: "processed")

    assert cached_entry.body == "encoded image"
    assert cached_entry.content_type == "image/webp"
    assert cached_entry.headers == [{"vary", "Accept"}]
    assert cached_entry.created_at == ~U[2026-04-29 10:15:00Z]

    assert File.exists?(
             Path.join([root, "processed", "ab", "cd", body_filename(cache_key, "encoded image")])
           )

    assert File.exists?(Path.join([root, "processed", "ab", "cd", cache_key.hash <> ".meta"]))
  end

  test "missing metadata or body is a miss", %{root: root} do
    cache_key = key("123456" <> String.duplicate("a", 58))
    assert FileSystem.get(cache_key, root: root) == :miss

    dir = Path.join([root, "12", "34"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, body_filename(cache_key, "body")), "body")

    assert FileSystem.get(cache_key, root: root) == :miss

    meta_only_key = key("223456" <> String.duplicate("a", 58))
    meta_only_dir = Path.join([root, "22", "34"])
    File.mkdir_p!(meta_only_dir)

    File.write!(
      Path.join(meta_only_dir, meta_only_key.hash <> ".meta"),
      :erlang.term_to_binary(metadata(meta_only_key, "body"))
    )

    assert FileSystem.get(meta_only_key, root: root) == :miss
  end

  test "invalid metadata is returned as an error", %{root: root} do
    cache_key = key("654321" <> String.duplicate("b", 58))
    dir = Path.join([root, "65", "43"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, body_filename(cache_key, "body")), "body")

    File.write!(
      Path.join(dir, cache_key.hash <> ".meta"),
      :erlang.term_to_binary(%{metadata_version: 999})
    )

    assert FileSystem.get(cache_key, root: root) ==
             {:error, {:invalid_metadata, :version_mismatch}}
  end

  test "invalid metadata is an error when fail_on_cache_error is true", %{root: root} do
    cache_key = key("754321" <> String.duplicate("b", 58))
    dir = Path.join([root, "75", "43"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, body_filename(cache_key, "body")), "body")

    File.write!(
      Path.join(dir, cache_key.hash <> ".meta"),
      :erlang.term_to_binary(%{metadata_version: 999})
    )

    assert FileSystem.get(cache_key, root: root, fail_on_cache_error: true) ==
             {:error, {:invalid_metadata, :version_mismatch}}
  end

  test "body byte-size mismatch is returned as invalid metadata", %{root: root} do
    cache_key = key("bbbbbb" <> String.duplicate("c", 58))
    assert FileSystem.put(cache_key, entry("12345"), root: root) == :ok

    dir = Path.join([root, "bb", "bb"])
    File.write!(Path.join(dir, body_filename(cache_key, "12345")), "123")

    assert FileSystem.get(cache_key, root: root) ==
             {:error, {:invalid_metadata, :body_byte_size_mismatch}}
  end

  test "same-size mixed body and metadata is invalid metadata", %{root: root} do
    cache_key = key("eeeeee" <> String.duplicate("1", 58))
    assert FileSystem.put(cache_key, entry("body-one"), root: root) == :ok

    dir = Path.join([root, "ee", "ee"])
    File.write!(Path.join(dir, body_filename(cache_key, "body-one")), "body-two")

    assert FileSystem.get(cache_key, root: root) ==
             {:error, {:invalid_metadata, :body_digest_mismatch}}

    assert FileSystem.get(cache_key, root: root, fail_on_cache_error: true) ==
             {:error, {:invalid_metadata, :body_digest_mismatch}}
  end

  test "metadata from an earlier concurrent writer still points at its own body", %{root: root} do
    cache_key = key("ababab" <> String.duplicate("1", 58))

    assert FileSystem.put(cache_key, entry("body-one"), root: root) == :ok
    assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
    metadata_one = File.read!(paths.meta_path)

    assert FileSystem.put(cache_key, entry("body-two"), root: root) == :ok
    File.write!(paths.meta_path, metadata_one)

    assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
    assert cached_entry.body == "body-one"
  end

  test "put succeeds when the content-addressed body already exists", %{root: root} do
    cache_key = key("adadad" <> String.duplicate("1", 58))
    assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
    File.mkdir_p!(paths.dir)
    File.write!(Path.join(paths.dir, body_filename(cache_key, "body")), "body")

    assert FileSystem.put(cache_key, entry("body"), root: root) == :ok
    assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
    assert cached_entry.body == "body"
  end

  test "unexpected body read error is returned", %{root: root} do
    cache_key = key("fafafa" <> String.duplicate("2", 58))
    assert FileSystem.put(cache_key, entry("body"), root: root) == :ok

    body_path = Path.join([root, "fa", "fa", body_filename(cache_key, "body")])
    File.rm!(body_path)
    File.mkdir_p!(body_path)

    assert FileSystem.get(cache_key, root: root) == {:error, {:body_read, :eisdir}}
  end

  test "cleans temp files when metadata write fails", %{root: root} do
    cache_key = key("cccccc" <> String.duplicate("d", 58))
    dir = Path.join([root, "cc", "cc"])
    File.mkdir_p!(dir)
    File.mkdir_p!(Path.join(dir, cache_key.hash <> ".meta"))

    assert {:error, _reason} = FileSystem.put(cache_key, entry(), root: root)
    refute File.ls!(dir) |> Enum.any?(&String.ends_with?(&1, ".tmp"))
  end

  test "does not replace an existing body when metadata destination is obstructed", %{root: root} do
    cache_key = key("cdcdcd" <> String.duplicate("d", 58))
    dir = Path.join([root, "cd", "cd"])
    File.mkdir_p!(dir)

    body_path = Path.join(dir, body_filename(cache_key, "old body"))
    meta_path = Path.join(dir, cache_key.hash <> ".meta")
    File.write!(body_path, "old body")
    File.mkdir_p!(meta_path)

    assert {:error, _reason} = FileSystem.put(cache_key, entry("new body"), root: root)
    assert File.read!(body_path) == "old body"
  end

  test "concurrent puts for the same key leave a readable entry", %{root: root} do
    cache_key = key("dddddd" <> String.duplicate("e", 58))

    results =
      ["body-one", "body-two"]
      |> Enum.map(fn body ->
        Task.async(fn -> FileSystem.put(cache_key, entry(body), root: root) end)
      end)
      |> Enum.map(&Task.await(&1, 5_000))

    assert results == [:ok, :ok]
    assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
    assert cached_entry.body in ["body-one", "body-two"]
  end
end
