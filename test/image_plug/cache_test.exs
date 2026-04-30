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

  defmodule CaptureAdapter do
    def get(%Key{} = key, opts) do
      send(self(), {:cache_get, key, opts})
      :miss
    end

    def put(%Key{}, %Entry{}, _opts), do: :ok
  end

  defmodule ErrorAdapter do
    def get(%Key{}, _opts), do: {:error, :read_failed}
    def put(%Key{}, %Entry{}, _opts), do: {:error, :write_failed}
  end

  defmodule UnexpectedResultAdapter do
    def get(%Key{}, _opts), do: :surprise
    def put(%Key{}, %Entry{}, _opts), do: :surprise
  end

  defmodule LookupOnlyAdapter do
    def get(%Key{}, _opts), do: :miss
  end

  defmodule ShouldNotBeCalledAdapter do
    def get(%Key{}, _opts), do: flunk("adapter should not be called for invalid cache config")

    def put(%Key{}, %Entry{}, _opts),
      do: flunk("adapter should not be called for invalid cache config")
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
      material: [schema_version: 2],
      serialized_material: :erlang.term_to_binary([schema_version: 2], [:deterministic])
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

  test "ImagePlug init rejects invalid cache config early" do
    assert_raise ArgumentError, ~r/invalid cache config/, fn ->
      ImagePlug.init(cache: {String, []})
    end
  end

  test "ImagePlug init rejects invalid filesystem cache options early" do
    assert_raise ArgumentError, ~r/invalid cache config/, fn ->
      ImagePlug.init(cache: {ImagePlug.Cache.FileSystem, root: "relative/cache"})
    end

    assert_raise ArgumentError, ~r/invalid cache config/, fn ->
      ImagePlug.init(
        cache: {ImagePlug.Cache.FileSystem, root: System.tmp_dir!(), path_prefix: "../outside"}
      )
    end

    assert_raise ArgumentError, ~r/invalid cache config/, fn ->
      ImagePlug.init(
        cache:
          {ImagePlug.Cache.FileSystem, root: System.tmp_dir!(), path_prefix: "processed//images"}
      )
    end
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

  test "lookup key opts affect key material without reaching adapter opts" do
    request = %ProcessingRequest{request() | format: nil}

    assert {:miss, %Key{} = key} =
             Cache.lookup(
               conn(:get, "/_/plain/images/cat.jpg"),
               request,
               "https://origin.test/cat.jpg",
               [cache: {CaptureAdapter, key_headers: ["accept-language"]}],
               selected_output_format: :avif
             )

    assert key.material[:output] == [format: :avif, automatic: true]
    assert_received {:cache_get, ^key, adapter_opts}
    refute Keyword.has_key?(adapter_opts, :selected_output_format)
    assert Keyword.fetch!(adapter_opts, :key_headers) == ["accept-language"]
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

  test "unexpected adapter get result is handled as a cache read error" do
    assert {:error, {:cache_read, {:invalid_adapter_result, :surprise}}} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {UnexpectedResultAdapter, fail_on_cache_error: true}
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

  test "put accepts nil and non-negative max_body_bytes values" do
    assert :ok =
             Cache.put(
               cache_key(),
               entry("123456"),
               cache: {MissAdapter, max_body_bytes: nil}
             )

    assert :ok =
             Cache.put(
               cache_key(),
               entry(""),
               cache: {MissAdapter, max_body_bytes: 0}
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

  test "unexpected adapter put result is handled as a cache write error" do
    assert {:error, {:cache_write, {:invalid_adapter_result, :surprise}}} =
             Cache.put(
               cache_key(),
               entry(),
               cache: {UnexpectedResultAdapter, fail_on_cache_error: true}
             )
  end

  test "invalid cache lookup config returns a cache read error instead of crashing" do
    assert {:error, {:cache_read, {:invalid_cache_config, ImagePlug.Cache.FileSystem}}} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: ImagePlug.Cache.FileSystem
             )

    assert {:error,
            {:cache_read,
             {:invalid_cache_config, {ImagePlug.Cache.FileSystem, %{root: "/tmp/cache"}}}}} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {ImagePlug.Cache.FileSystem, %{root: "/tmp/cache"}}
             )
  end

  test "invalid cache write config returns a cache write error instead of crashing" do
    assert {:error, {:cache_write, {:invalid_cache_config, ImagePlug.Cache.FileSystem}}} =
             Cache.put(cache_key(), entry(), cache: ImagePlug.Cache.FileSystem)

    assert {:error,
            {:cache_write,
             {:invalid_cache_config, {ImagePlug.Cache.FileSystem, %{root: "/tmp/cache"}}}}} =
             Cache.put(
               cache_key(),
               entry(),
               cache: {ImagePlug.Cache.FileSystem, %{root: "/tmp/cache"}}
             )
  end

  test "invalid key header and cookie config returns a cache read error before key building" do
    assert {:error, {:cache_read, {:invalid_cache_config, {:key_headers, [:accept_language]}}}} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {ShouldNotBeCalledAdapter, key_headers: [:accept_language]}
             )

    assert {:error, {:cache_read, {:invalid_cache_config, {:key_cookies, [:tenant]}}}} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {ShouldNotBeCalledAdapter, key_cookies: [:tenant]}
             )
  end

  test "invalid cache option lists return cache errors before adapter calls" do
    assert {:error, {:cache_read, {:invalid_cache_config, {ShouldNotBeCalledAdapter, [:root]}}}} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {ShouldNotBeCalledAdapter, [:root]}
             )

    assert {:error, {:cache_write, {:invalid_cache_config, {ShouldNotBeCalledAdapter, [:root]}}}} =
             Cache.put(cache_key(), entry(), cache: {ShouldNotBeCalledAdapter, [:root]})
  end

  test "invalid fail_on_cache_error config returns cache errors before adapter calls" do
    assert {:error, {:cache_read, {:invalid_cache_config, {:fail_on_cache_error, "false"}}}} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {ShouldNotBeCalledAdapter, fail_on_cache_error: "false"}
             )

    assert {:error, {:cache_write, {:invalid_cache_config, {:fail_on_cache_error, 1}}}} =
             Cache.put(cache_key(), entry(),
               cache: {ShouldNotBeCalledAdapter, fail_on_cache_error: 1}
             )
  end

  test "invalid max_body_bytes config returns cache errors instead of changing cache policy" do
    assert {:error, {:cache_read, {:invalid_cache_config, {:max_body_bytes, "10MB"}}}} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {ShouldNotBeCalledAdapter, max_body_bytes: "10MB"}
             )

    assert {:error, {:cache_write, {:invalid_cache_config, {:max_body_bytes, -1}}}} =
             Cache.put(cache_key(), entry(),
               cache: {ShouldNotBeCalledAdapter, max_body_bytes: -1}
             )
  end

  test "invalid adapter config returns cache errors instead of crashing" do
    assert {:error, {:cache_read, {:invalid_cache_config, {:adapter, String}}}} =
             Cache.lookup(
               conn(:get, "/_/format:webp/plain/images/cat.jpg"),
               request(),
               "https://origin.test/cat.jpg",
               cache: {String, []}
             )

    assert {:error, {:cache_write, {:invalid_cache_config, {:adapter, LookupOnlyAdapter}}}} =
             Cache.put(cache_key(), entry(), cache: {LookupOnlyAdapter, []})
  end
end
