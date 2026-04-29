defmodule ImagePlug.CacheTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.ProcessingRequest

  defmodule HitAdapter do
    def get(%Key{}, opts), do: {:hit, Keyword.fetch!(opts, :entry)}
    def put(%Key{}, %Entry{}, _opts), do: :ok
  end

  defmodule MissAdapter do
    def get(%Key{}, _opts), do: :miss
    def put(%Key{}, %Entry{}, _opts), do: :ok
  end

  defmodule ErrorAdapter do
    def get(%Key{}, _opts), do: {:error, :read_failed}
    def put(%Key{}, %Entry{}, _opts), do: {:error, :write_failed}
  end

  defp request do
    %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"],
      format: :webp
    }
  end

  defp entry(body \\ "body") do
    %Entry{
      body: body,
      content_type: "image/webp",
      headers: [],
      created_at: ~U[2026-04-29 10:15:00Z]
    }
  end

  defp cache_key do
    %Key{
      hash: String.duplicate("a", 64),
      material: [schema_version: 1],
      serialized_material: :erlang.term_to_binary([schema_version: 1], [:deterministic])
    }
  end

  test "returns disabled when no cache is configured" do
    assert Cache.lookup(
             conn(:get, "/_/plain/images/cat.jpg"),
             request(),
             "https://origin.test/cat.jpg",
             []
           ) ==
             :disabled
  end

  test "returns hits with the generated key" do
    configured_entry = entry()

    assert {:hit, %Key{} = key, ^configured_entry} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {HitAdapter, entry: configured_entry}
             )

    assert key.material[:origin_identity] == "https://origin.test/cat.jpg"
  end

  test "returns miss with the generated key" do
    assert {:miss, %Key{} = key} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {MissAdapter, []}
             )

    assert key.hash =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "read errors fail open by default and are logged" do
    log =
      capture_log(fn ->
        assert {:miss, %Key{}} =
                 Cache.lookup(
                   conn(:get, "/_/format:webp/plain/images/cat.jpg"),
                   request(),
                   "https://origin.test/cat.jpg",
                   cache: {ErrorAdapter, []}
                 )
      end)

    assert log =~ "cache read error"
    assert log =~ ":read_failed"
  end

  test "read errors are returned when fail_on_cache_error is true" do
    assert {:error, {:cache_read, :read_failed}} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {ErrorAdapter, fail_on_cache_error: true}
             )
  end

  test "put skips bodies over max_body_bytes" do
    assert :skipped =
             Cache.put(
               cache_key(),
               entry("123456"),
               cache: {ErrorAdapter, max_body_bytes: 5}
             )
  end

  test "write errors fail open by default and are logged" do
    log =
      capture_log(fn ->
        assert :ok =
                 Cache.put(
                   cache_key(),
                   entry(),
                   cache: {ErrorAdapter, []}
                 )
      end)

    assert log =~ "cache write error"
    assert log =~ ":write_failed"
  end

  test "write errors are returned when fail_on_cache_error is true" do
    assert {:error, {:cache_write, :write_failed}} =
             Cache.put(
               cache_key(),
               entry(),
               cache: {ErrorAdapter, fail_on_cache_error: true}
             )
  end
end
