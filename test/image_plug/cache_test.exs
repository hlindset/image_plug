defmodule ImagePlug.CacheTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source

  defmodule HitAdapter do
    @behaviour ImagePlug.Cache

    def get(%Key{}, opts), do: {:hit, Keyword.fetch!(opts, :entry)}
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule MissAdapter do
    @behaviour ImagePlug.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule CaptureAdapter do
    @behaviour ImagePlug.Cache

    def get(%Key{} = key, opts) do
      send(self(), {:cache_get, key, opts})
      :miss
    end

    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule ErrorAdapter do
    @behaviour ImagePlug.Cache

    def get(%Key{}, _opts), do: {:error, :read_failed}
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:error, :open_failed}
    def write_chunk(state, _chunk, _opts), do: {:error, :write_failed, state}
    def commit_sink(_state, _opts), do: {:error, :commit_failed}
    def abort_sink(_state, _opts), do: {:error, :abort_failed}
  end

  defmodule UnexpectedResultAdapter do
    @behaviour ImagePlug.Cache

    def get(%Key{}, _opts), do: :surprise
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :surprise
    def abort_sink(_state, _opts), do: :surprise
  end

  defmodule LookupOnlyAdapter do
    def get(%Key{}, _opts), do: :miss
  end

  defmodule ShouldNotBeCalledAdapter do
    @behaviour ImagePlug.Cache

    def get(%Key{}, _opts), do: flunk("adapter should not be called for invalid cache config")

    def open_sink(%Key{}, %Entry.Metadata{}, _opts),
      do: flunk("adapter should not be called for invalid cache config")

    def write_chunk(_state, _chunk, _opts),
      do: flunk("adapter should not be called for invalid cache config")

    def commit_sink(_state, _opts),
      do: flunk("adapter should not be called for invalid cache config")

    def abort_sink(_state, _opts),
      do: flunk("adapter should not be called for invalid cache config")
  end

  defmodule SinkMissAdapter do
    @behaviour ImagePlug.Cache

    def get(%Key{}, _opts), do: :miss

    def open_sink(%Key{} = key, %Entry.Metadata{} = metadata, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:open_sink, key, metadata, opts})
      {:ok, %{chunks: [], opts: opts}}
    end

    def write_chunk(state, chunk, _opts) when is_binary(chunk) do
      send(Keyword.fetch!(state.opts, :test_pid), {:write_chunk, chunk})
      {:ok, %{state | chunks: [chunk | state.chunks]}}
    end

    def commit_sink(state, _opts) do
      send(Keyword.fetch!(state.opts, :test_pid), {:commit_sink, state.chunks})
      :ok
    end

    def abort_sink(state, _opts) do
      send(Keyword.fetch!(state.opts, :test_pid), {:abort_sink, state.chunks})
      :ok
    end
  end

  defmodule SinkWriteErrorAdapter do
    @behaviour ImagePlug.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{aborted?: false}}
    def write_chunk(state, _chunk, _opts), do: {:error, :write_failed, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule SinkCommitErrorAdapter do
    @behaviour ImagePlug.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: {:error, :commit_failed}
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule SinkAbortErrorAdapter do
    @behaviour ImagePlug.Cache

    def get(%Key{}, _opts), do: :miss
    def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
    def write_chunk(state, _chunk, _opts), do: {:ok, state}
    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: {:error, :abort_failed}
  end

  defmodule LegacyPutOnlyAdapter do
    def get(%Key{}, _opts), do: :miss
    def put(%Key{}, %Entry{}, _opts), do: :ok
  end

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: %Source.Path{segments: ["images", "cat.jpg"]},
          pipelines: [%Pipeline{operations: []}],
          output: %Output{mode: {:explicit, :webp}}
        ],
        overrides
      )
    )
  end

  defp automatic_plan do
    plan(output: %Output{mode: :automatic})
  end

  defp source_identity do
    [kind: :path, adapter: :path, root: "default", path: ["images", "cat.jpg"]]
  end

  defp cache_key do
    %Key{
      hash: String.duplicate("a", 64),
      data: [schema_version: 2],
      serialized_data: :erlang.term_to_binary([schema_version: 2], [:deterministic])
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

  defp resolved_output do
    %Resolved{format: :webp, quality: nil, response_headers: []}
  end

  test "returns disabled when no cache is configured" do
    assert Cache.lookup(
             conn(:get, "/_/plain/images/cat.jpg"),
             plan(),
             source_identity(),
             []
           ) ==
             :disabled
  end

  test "ImagePlug init rejects invalid cache config early" do
    assert_raise ArgumentError, ~r/invalid cache config/, fn ->
      ImagePlug.init(
        parser: ImagePlug.Parser.Imgproxy,
        sources: [
          path: {ImagePlug.Source.File, root: "priv/static", root_id: "static"}
        ],
        cache: {__MODULE__.DoesNotExist, []}
      )
    end
  end

  test "ImagePlug init rejects missing required options early" do
    assert_raise ArgumentError, ~r/required :parser option not found/, fn ->
      ImagePlug.init([])
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

  test "ImagePlug init preserves normalized filesystem cache options" do
    root = Path.join(System.tmp_dir!(), "image_plug_cache_init")

    opts =
      ImagePlug.init(
        parser: ImagePlug.Parser.Imgproxy,
        sources: [
          path: {ImagePlug.Source.File, root: "priv/static", root_id: "static"}
        ],
        cache: {ImagePlug.Cache.FileSystem, root: root <> "/../image_plug_cache_init"}
      )

    assert {ImagePlug.Cache.FileSystem, cache_opts} = Keyword.fetch!(opts, :cache)
    assert cache_opts[:root] == Path.expand(root)
    assert cache_opts[:path_prefix] == ""
  end

  test "returns hits with the generated key" do
    configured_entry = entry()

    assert {:hit, %Key{} = key, ^configured_entry} =
             Cache.lookup(
               conn(:get, "/_/f:webp/plain/images/cat.jpg"),
               plan(),
               source_identity(),
               cache: {HitAdapter, entry: configured_entry}
             )

    assert key.data[:source_identity] == source_identity()
  end

  test "invalid hit content types are cache read errors" do
    invalid_entry = %Entry{
      body: "body",
      content_type: "image/gif",
      headers: [],
      created_at: ~U[2026-04-29 10:15:00Z]
    }

    log =
      capture_log(fn ->
        assert {:miss, %Key{},
                {:cache_read, {:invalid_entry, {:unsupported_output_format, "image/gif"}}}} =
                 Cache.lookup(
                   conn(:get, "/_/f:webp/plain/images/cat.jpg"),
                   plan(),
                   source_identity(),
                   cache: {HitAdapter, entry: invalid_entry}
                 )
      end)

    assert log =~ "cache read error"
    assert log =~ "unsupported_output_format"
  end

  test "returns miss with the generated key" do
    assert {:miss, %Key{} = key} =
             Cache.lookup(
               conn(:get, "/_/f:webp/plain/images/cat.jpg"),
               plan(),
               source_identity(),
               cache: {MissAdapter, []}
             )

    assert key.hash =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "automatic lookup key uses modern candidates without reaching adapter opts" do
    assert {:miss, %Key{} = key} =
             Cache.lookup(
               :get
               |> conn("/_/plain/images/cat.jpg")
               |> Plug.Conn.put_req_header("accept", "image/avif,image/webp"),
               automatic_plan(),
               source_identity(),
               auto_avif: false,
               cache: {CaptureAdapter, key_headers: ["accept-language"]}
             )

    assert key.data[:output] == [
             mode: :automatic,
             modern_candidates: [:webp],
             auto: [avif: false, webp: true],
             quality: :default,
             format_qualities: %{}
           ]

    assert_received {:cache_get, ^key, adapter_opts}
    refute Keyword.has_key?(adapter_opts, :selected_output_format)
    refute Keyword.has_key?(adapter_opts, :selected_output_reason)
    refute Keyword.has_key?(adapter_opts, :auto_avif)
    assert Keyword.fetch!(adapter_opts, :key_headers) == ["accept-language"]
  end

  test "adapter-private options named like automatic output flags do not affect key data" do
    assert {:miss, %Key{} = key} =
             Cache.lookup(
               :get
               |> conn("/_/plain/images/cat.jpg")
               |> Plug.Conn.put_req_header("accept", "image/avif,image/webp"),
               automatic_plan(),
               source_identity(),
               cache: {CaptureAdapter, auto_avif: false, auto_webp: false}
             )

    assert key.data[:output][:auto] == [avif: true, webp: true]

    assert_received {:cache_get, ^key, adapter_opts}
    assert Keyword.fetch!(adapter_opts, :auto_avif) == false
    assert Keyword.fetch!(adapter_opts, :auto_webp) == false
  end

  test "read errors fail open by default and are logged" do
    log =
      capture_log(fn ->
        assert {:miss, %Key{}, {:cache_read, :read_failed}} =
                 Cache.lookup(
                   conn(:get, "/_/f:webp/plain/images/cat.jpg"),
                   plan(),
                   source_identity(),
                   cache: {ErrorAdapter, []}
                 )
      end)

    assert log =~ "cache read error"
    assert log =~ ":read_failed"
  end

  test "unexpected adapter get result is handled as a cache read error" do
    log =
      capture_log(fn ->
        assert {:miss, %Key{}, {:cache_read, {:invalid_adapter_result, :surprise}}} =
                 Cache.lookup(
                   conn(:get, "/_/f:webp/plain/images/cat.jpg"),
                   plan(),
                   source_identity(),
                   cache: {UnexpectedResultAdapter, []}
                 )
      end)

    assert log =~ "cache read error"
    assert log =~ ":surprise"
  end

  test "open_sink builds body-free metadata from resolved output" do
    resolved_output = %Resolved{
      format: :webp,
      quality: nil,
      response_headers: [{"Vary", "Accept"}, {"x-private", "drop"}]
    }

    sink =
      Cache.open_sink(cache_key(), resolved_output, cache: {SinkMissAdapter, test_pid: self()})

    assert_received {:open_sink, %Key{}, %Entry.Metadata{} = metadata, adapter_opts}
    assert metadata.content_type == "image/webp"
    assert metadata.headers == [{"vary", "Accept"}]
    assert %DateTime{} = metadata.created_at
    assert metadata.output_format == :webp
    assert Keyword.fetch!(adapter_opts, :test_pid) == self()
    assert sink
  end

  test "write_chunk and commit_sink dispatch through the adapter sink state" do
    sink =
      cache_key()
      |> Cache.open_sink(resolved_output(), cache: {SinkMissAdapter, test_pid: self()})
      |> Cache.write_chunk("abc", cache: {SinkMissAdapter, test_pid: self()})
      |> Cache.write_chunk("def", cache: {SinkMissAdapter, test_pid: self()})

    assert :ok = Cache.commit_sink(sink, cache: {SinkMissAdapter, test_pid: self()})
    assert_received {:write_chunk, "abc"}
    assert_received {:write_chunk, "def"}
    assert_received {:commit_sink, ["def", "abc"]}
  end

  test "abort_sink dispatches cleanup and returns ok" do
    sink =
      Cache.open_sink(cache_key(), resolved_output(), cache: {SinkMissAdapter, test_pid: self()})

    assert :ok = Cache.abort_sink(sink, :cancelled, cache: {SinkMissAdapter, test_pid: self()})
    assert_received {:abort_sink, []}
  end

  test "open_sink fails open and logs adapter errors" do
    attach_telemetry([[:image_plug, :cache, :stage, :stop]])

    log =
      capture_log(fn ->
        assert Cache.open_sink(cache_key(), resolved_output(), cache: {ErrorAdapter, []}) == nil
      end)

    assert log =~ "cache sink open error"
    assert log =~ ":open_failed"

    assert_receive {:telemetry_event, [:image_plug, :cache, :stage, :stop], _measurements,
                    %{cache: :stage_error, error: :open_failed, output_format: :webp}}
  end

  test "write_chunk drops the sink when max_body_bytes would be crossed" do
    attach_telemetry([[:image_plug, :cache, :stage, :stop]])

    sink =
      Cache.open_sink(cache_key(), resolved_output(),
        cache: {SinkMissAdapter, test_pid: self(), max_body_bytes: 3}
      )

    assert Cache.write_chunk(sink, "abcd",
             cache: {SinkMissAdapter, test_pid: self(), max_body_bytes: 3}
           ) == nil

    assert_received {:abort_sink, []}

    assert_receive {:telemetry_event, [:image_plug, :cache, :stage, :stop], _measurements,
                    %{cache: :stage_skipped, reason: :too_large, output_format: :webp}}
  end

  test "write_chunk adapter errors abort and fail open" do
    attach_telemetry([[:image_plug, :cache, :stage, :stop]])

    sink = Cache.open_sink(cache_key(), resolved_output(), cache: {SinkWriteErrorAdapter, []})

    assert Cache.write_chunk(sink, "abc", cache: {SinkWriteErrorAdapter, []}) == nil

    assert_receive {:telemetry_event, [:image_plug, :cache, :stage, :stop], _measurements,
                    %{cache: :stage_error, error: :write_failed, output_format: :webp}}
  end

  test "commit_sink adapter errors fail open through cache write telemetry" do
    attach_telemetry([[:image_plug, :cache, :write, :stop]])

    sink =
      cache_key()
      |> Cache.open_sink(resolved_output(), cache: {SinkCommitErrorAdapter, []})
      |> Cache.write_chunk("abc", cache: {SinkCommitErrorAdapter, []})

    assert :ok = Cache.commit_sink(sink, cache: {SinkCommitErrorAdapter, []})

    assert_receive {:telemetry_event, [:image_plug, :cache, :write, :stop], _measurements,
                    %{result: :cache_error, cache: :write_error, error: :commit_failed}}
  end

  test "abort_sink adapter errors fail open through cleanup telemetry" do
    attach_telemetry([[:image_plug, :cache, :stage, :stop]])

    sink =
      cache_key()
      |> Cache.open_sink(resolved_output(), cache: {SinkAbortErrorAdapter, []})
      |> Cache.write_chunk("abc", cache: {SinkAbortErrorAdapter, []})

    assert :ok = Cache.abort_sink(sink, :cancelled, cache: {SinkAbortErrorAdapter, []})

    assert_receive {:telemetry_event, [:image_plug, :cache, :stage, :stop], _measurements,
                    %{cache: :stage_cleanup_error, error: :abort_failed, output_format: :webp}}
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

  test "put writes through the sink callbacks" do
    assert :ok =
             Cache.put(cache_key(), entry("abcdef"), cache: {SinkMissAdapter, test_pid: self()})

    assert_received {:write_chunk, "abcdef"}
    assert_received {:commit_sink, ["abcdef"]}
  end

  test "write errors fail open by default and are logged" do
    log =
      capture_log(fn ->
        assert {:ok, {:cache_write, :write_failed}} =
                 Cache.put(
                   cache_key(),
                   entry(),
                   cache: {SinkWriteErrorAdapter, []}
                 )
      end)

    assert log =~ "cache sink write error"
    assert log =~ ":write_failed"
  end

  test "unexpected adapter commit result is handled as a cache write error" do
    log =
      capture_log(fn ->
        assert {:ok, {:cache_write, {:invalid_adapter_result, :surprise}}} =
                 Cache.put(
                   cache_key(),
                   entry(),
                   cache: {UnexpectedResultAdapter, []}
                 )
      end)

    assert log =~ "cache sink commit error"
    assert log =~ ":surprise"
  end

  test "invalid cache lookup config returns a cache read error instead of crashing" do
    assert {:error, {:cache_read, {:invalid_cache_config, ImagePlug.Cache.FileSystem}}} =
             Cache.lookup(
               conn(:get, "/_/f:webp/plain/images/cat.jpg"),
               plan(),
               source_identity(),
               cache: ImagePlug.Cache.FileSystem
             )

    assert {:error,
            {:cache_read,
             {:invalid_cache_config, {ImagePlug.Cache.FileSystem, %{root: "/tmp/cache"}}}}} =
             Cache.lookup(
               conn(:get, "/_/f:webp/plain/images/cat.jpg"),
               plan(),
               source_identity(),
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
               conn(:get, "/_/f:webp/plain/images/cat.jpg"),
               plan(),
               source_identity(),
               cache: {ShouldNotBeCalledAdapter, key_headers: [:accept_language]}
             )

    assert {:error, {:cache_read, {:invalid_cache_config, {:key_cookies, [:tenant]}}}} =
             Cache.lookup(
               conn(:get, "/_/f:webp/plain/images/cat.jpg"),
               plan(),
               source_identity(),
               cache: {ShouldNotBeCalledAdapter, key_cookies: [:tenant]}
             )
  end

  test "key build errors return cache read errors instead of crashing" do
    source_identity = [kind: :path, client: self()]

    assert {:error, {:cache_read, {:invalid_source_identity, ^source_identity}}} =
             Cache.lookup(
               conn(:get, "/_/f:webp/plain/images/cat.jpg"),
               plan(),
               source_identity,
               cache: {ShouldNotBeCalledAdapter, []}
             )
  end

  test "invalid cache option lists return cache errors before adapter calls" do
    assert {:error, {:cache_read, {:invalid_cache_config, {ShouldNotBeCalledAdapter, [:root]}}}} =
             Cache.lookup(
               conn(:get, "/_/f:webp/plain/images/cat.jpg"),
               plan(),
               source_identity(),
               cache: {ShouldNotBeCalledAdapter, [:root]}
             )

    assert {:error, {:cache_write, {:invalid_cache_config, {ShouldNotBeCalledAdapter, [:root]}}}} =
             Cache.put(cache_key(), entry(), cache: {ShouldNotBeCalledAdapter, [:root]})
  end

  test "invalid max_body_bytes config returns cache errors instead of changing cache policy" do
    assert {:error, {:cache_read, {:invalid_cache_config, {:max_body_bytes, "10MB"}}}} =
             Cache.lookup(
               conn(:get, "/_/f:webp/plain/images/cat.jpg"),
               plan(),
               source_identity(),
               cache: {ShouldNotBeCalledAdapter, max_body_bytes: "10MB"}
             )

    assert {:error, {:cache_write, {:invalid_cache_config, {:max_body_bytes, -1}}}} =
             Cache.put(cache_key(), entry(),
               cache: {ShouldNotBeCalledAdapter, max_body_bytes: -1}
             )
  end

  test "unloaded adapter config returns cache errors instead of crashing" do
    adapter = Module.concat(__MODULE__, DefinitelyNotLoadedCacheAdapter)

    assert {:error, {:cache_read, {:invalid_cache_config, {:adapter, ^adapter}}}} =
             Cache.lookup(
               conn(:get, "/_/f:webp/plain/images/cat.jpg"),
               plan(),
               source_identity(),
               cache: {adapter, []}
             )

    assert {:error, {:cache_write, {:invalid_cache_config, {:adapter, ^adapter}}}} =
             Cache.put(cache_key(), entry(), cache: {adapter, []})
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp attach_telemetry(events) do
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
