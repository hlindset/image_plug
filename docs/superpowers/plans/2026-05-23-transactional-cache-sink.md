# Transactional Cache Sink Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `SourceSession.CacheBuffer` with a cache-owned transactional sink that stages streamed encoded bytes without holding a complete response body in ImagePlug memory.

**Architecture:** `ImagePlug.Cache` owns sink state, cache metadata construction, size-limit enforcement, fail-open cache errors, and adapter dispatch. `ImagePlug.Request.SourceSession` stores an opaque `nil | Cache.sink()` and calls cache API functions while it owns the lazy encoder continuation. `ImagePlug.Cache.FileSystem` stages bytes to temporary files and makes entries visible only when commit writes metadata last.

**Tech Stack:** Elixir, OTP `GenServer`, `Enumerable.reduce/3` suspension, Plug prepared-stream response delivery, ExUnit, Boundary, filesystem cache adapter, pinned Vix fork `3a30758d44526d3c914b2076bd0be201c972f2b7`, `mise exec -- mix`.

---

## Preconditions

This plan starts from:

- `a03a3ca Remove stale direct image response path`
- `b15642d Remove fail-closed cache runtime option`
- `942e6bc Clarify cache sink after direct path removal`

Runtime processed responses are only cache hits or prepared streams. Don't restore the removed sender-side `{:image, state, resolved_output, response}` path.

Keep Vix pinned in `mix.exs`:

```elixir
{:vix,
 git: "https://github.com/hlindset/vix.git",
 ref: "3a30758d44526d3c914b2076bd0be201c972f2b7",
 override: true}
```

Run focused tests involving Vix with:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test ...
```

This slice is cache sink implementation only. Don't add S3 caching, cache writer GenServers, public docs, or `Response.Sender` changes.

## Files

- Create: `lib/image_plug/cache/sink.ex`
- Create: `lib/image_plug/cache/entry/metadata.ex`
- Edit: `lib/image_plug/cache.ex`
- Edit: `lib/image_plug/cache/file_system.ex`
- Edit: `lib/image_plug/request/source_session.ex`
- Delete: `lib/image_plug/request/source_session/cache_buffer.ex`
- Edit: `test/image_plug/cache_test.exs`
- Edit: `test/image_plug/cache/file_system_test.exs`
- Edit: `test/image_plug/request/source_session_test.exs`
- Edit: `test/image_plug/request_runner_test.exs`
- Edit: `test/image_plug/telemetry_test.exs`
- Edit: `test/image_plug/architecture_boundary_test.exs`
- Read as needed: `lib/image_plug/cache/entry.ex`
- Read as needed: `lib/image_plug/output/resolved.ex`
- Read as needed: `lib/image_plug/response/sender.ex`
- Read as needed: `docs/superpowers/designs/2026-05-23-transactional-cache-sink.md`

## Non-Goals

- Don't change `ImagePlug.Response.Sender`.
- Don't add S3 cache support.
- Don't add cache writer processes.
- Don't add new public docs.
- Don't add cache sink configuration beyond the existing `:max_body_bytes`.
- Don't preserve behavior for impossible internal misuse.
- Don't keep `SourceSession.CacheBuffer`.
- Don't let `SourceSession` inspect sink adapter, key, metadata, state, or status fields.

## Contracts

`ImagePlug.Cache` exposes the only sink API used outside the cache boundary:

```elixir
@opaque sink :: %ImagePlug.Cache.Sink{}

@spec open_sink(Key.t() | nil, Resolved.t(), keyword()) :: sink() | nil
@spec write_chunk(sink() | nil, binary(), keyword()) :: sink() | nil
@spec commit_sink(sink() | nil, keyword()) :: :ok
@spec abort_sink(sink() | nil, atom(), keyword()) :: :ok
```

Runtime cache sink errors fail open:

- `open_sink/3` returns `nil` when cache is disabled, invalid at runtime, unsupported by the adapter, or adapter open fails.
- `write_chunk/3` returns `nil` when size limit is crossed or adapter write fails.
- `commit_sink/2` returns `:ok` even when adapter commit fails.
- `abort_sink/3` returns `:ok` even when cleanup fails.

The cache coordinator emits telemetry and logs for those failures. `SourceSession.prepare/1` and `SourceSession.next/1` must not turn cache errors into image-processing failures.

`abort_sink/3` returns `:ok`, so it can't mutate a previously returned sink
value. Repeated cleanup at this API means `SourceSession` clears its stored sink
after aborting and adapters must tolerate repeated cleanup for the same adapter
state. Don't claim that `Cache.abort_sink/3` can prevent repeated calls when a
caller reuses the same old sink value.

The adapter write contract becomes sink-based:

```elixir
@callback open_sink(Key.t(), Entry.Metadata.t(), keyword()) ::
            {:ok, state()} | {:error, term()}

@callback write_chunk(state(), binary(), keyword()) ::
            {:ok, state()} | {:error, term(), state()}

@callback commit_sink(state(), keyword()) ::
            :ok | {:error, term()}

@callback abort_sink(state(), keyword()) ::
            :ok | {:error, term()}
```

`Cache.put/3` may stay as a cache API helper for tests and whole-body callers, but it must be implemented through `open_sink/3`, `write_chunk/3`, and `commit_sink/2`. Adapter modules shouldn't keep a separate `put/3` callback.

`ImagePlug.Cache.Entry.Metadata` is body-free cache metadata:

```elixir
%ImagePlug.Cache.Entry.Metadata{
  content_type: String.t(),
  headers: [ImagePlug.Cache.Entry.header()],
  created_at: DateTime.t(),
  output_format: atom()
}
```

The cache coordinator builds this metadata from `ImagePlug.Output.Resolved`. `SourceSession` passes the resolved output to `Cache.open_sink/3`; it doesn't call `Entry.cacheable_headers/1` or `Format.mime_type!/1`.

## Task 1: Add Cache API Sink Tests

Prove cache coordinator semantics before implementing the sink API.

**Files:**
- Edit: `test/image_plug/cache_test.exs`

- [ ] **Step 1: Replace write test adapters with sink-aware adapters**

Add sink-aware test adapters near the current adapter modules:

```elixir
defmodule SinkMissAdapter do
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

defmodule SinkErrorAdapter do
  def get(%Key{}, _opts), do: {:error, :read_failed}
  def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:error, :open_failed}
  def write_chunk(state, _chunk, _opts), do: {:error, :write_failed, state}
  def commit_sink(_state, _opts), do: {:error, :commit_failed}
  def abort_sink(_state, _opts), do: {:error, :abort_failed}
end

defmodule SinkWriteErrorAdapter do
  def get(%Key{}, _opts), do: :miss
  def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{aborted?: false}}
  def write_chunk(state, _chunk, _opts), do: {:error, :write_failed, state}
  def commit_sink(_state, _opts), do: :ok
  def abort_sink(_state, _opts), do: :ok
end

defmodule SinkCommitErrorAdapter do
  def get(%Key{}, _opts), do: :miss
  def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
  def write_chunk(state, _chunk, _opts), do: {:ok, state}
  def commit_sink(_state, _opts), do: {:error, :commit_failed}
  def abort_sink(_state, _opts), do: :ok
end

defmodule SinkAbortErrorAdapter do
  def get(%Key{}, _opts), do: :miss
  def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: {:ok, %{}}
  def write_chunk(state, _chunk, _opts), do: {:ok, state}
  def commit_sink(_state, _opts), do: :ok
  def abort_sink(_state, _opts), do: {:error, :abort_failed}
end

defmodule SinkUnexpectedResultAdapter do
  def get(%Key{}, _opts), do: :surprise
  def open_sink(%Key{}, %Entry.Metadata{}, _opts), do: :surprise
  def write_chunk(state, _chunk, _opts), do: {:ok, state}
  def commit_sink(_state, _opts), do: :surprise
  def abort_sink(_state, _opts), do: :surprise
end

defmodule LegacyPutOnlyAdapter do
  def get(%Key{}, _opts), do: :miss
  def put(%Key{}, %Entry{}, _opts), do: :ok
end
```

Keep lookup-only adapters for invalid adapter tests, but update expectations so a valid cache adapter must export sink callbacks.

- [ ] **Step 2: Add tests for open, write, commit, and abort semantics**

Add focused tests:

```elixir
test "open_sink builds body-free metadata from resolved output" do
  resolved_output = %ImagePlug.Output.Resolved{
    format: :webp,
    quality: nil,
    response_headers: [{"Vary", "Accept"}, {"x-private", "drop"}]
  }

  sink =
    Cache.open_sink(cache_key(), resolved_output,
      cache: {SinkMissAdapter, test_pid: self()}
    )

  assert_received {:open_sink, %Key{}, %Entry.Metadata{} = metadata, adapter_opts}
  assert metadata.content_type == "image/webp"
  assert metadata.headers == [{"vary", "Accept"}]
  assert %DateTime{} = metadata.created_at
  assert metadata.output_format == :webp
  assert Keyword.fetch!(adapter_opts, :test_pid) == self()
  assert sink
end

test "write_chunk and commit_sink dispatch through the adapter sink state" do
  resolved_output = resolved_output()

  sink =
    cache_key()
    |> Cache.open_sink(resolved_output, cache: {SinkMissAdapter, test_pid: self()})
    |> Cache.write_chunk("abc", cache: {SinkMissAdapter, test_pid: self()})
    |> Cache.write_chunk("def", cache: {SinkMissAdapter, test_pid: self()})

  assert :ok = Cache.commit_sink(sink, cache: {SinkMissAdapter, test_pid: self()})
  assert_received {:write_chunk, "abc"}
  assert_received {:write_chunk, "def"}
  assert_received {:commit_sink, ["def", "abc"]}
end

test "abort_sink dispatches cleanup and returns ok" do
  sink =
    Cache.open_sink(cache_key(), resolved_output(),
      cache: {SinkMissAdapter, test_pid: self()}
    )

  assert :ok = Cache.abort_sink(sink, :cancelled, cache: {SinkMissAdapter, test_pid: self()})
  assert_received {:abort_sink, []}
end
```

Use a local helper:

```elixir
defp resolved_output do
  %ImagePlug.Output.Resolved{format: :webp, quality: nil, response_headers: []}
end
```

- [ ] **Step 3: Add fail-open cache sink tests**

Add tests for runtime failures:

```elixir
test "open_sink fails open and logs adapter errors" do
  attach_telemetry([[:image_plug, :cache, :tee, :stop]])

  log =
    capture_log(fn ->
      assert Cache.open_sink(cache_key(), resolved_output(),
               cache: {SinkErrorAdapter, []}
             ) == nil
    end)

  assert log =~ "cache sink open error"
  assert log =~ ":open_failed"

  assert_receive {:telemetry_event, [:image_plug, :cache, :tee, :stop], _measurements,
                  %{cache: :write_error, error: :open_failed, output_format: :webp}}
end

test "write_chunk drops the sink when max_body_bytes would be crossed" do
  attach_telemetry([[:image_plug, :cache, :tee, :stop]])

  sink =
    Cache.open_sink(cache_key(), resolved_output(),
      cache: {SinkMissAdapter, test_pid: self(), max_body_bytes: 3}
    )

  assert Cache.write_chunk(sink, "abcd",
           cache: {SinkMissAdapter, test_pid: self(), max_body_bytes: 3}
         ) == nil

  assert_received {:abort_sink, []}

  assert_receive {:telemetry_event, [:image_plug, :cache, :tee, :stop], _measurements,
                  %{cache: :write_skipped, reason: :too_large, output_format: :webp}}
end

test "write_chunk adapter errors abort and fail open" do
  attach_telemetry([[:image_plug, :cache, :tee, :stop]])

  sink =
    Cache.open_sink(cache_key(), resolved_output(),
      cache: {SinkWriteErrorAdapter, []}
    )

  assert Cache.write_chunk(sink, "abc", cache: {SinkWriteErrorAdapter, []}) == nil

  assert_receive {:telemetry_event, [:image_plug, :cache, :tee, :stop], _measurements,
                  %{cache: :write_error, error: :write_failed, output_format: :webp}}
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
  attach_telemetry([[:image_plug, :cache, :tee, :stop]])

  sink =
    cache_key()
    |> Cache.open_sink(resolved_output(), cache: {SinkAbortErrorAdapter, []})
    |> Cache.write_chunk("abc", cache: {SinkAbortErrorAdapter, []})

  assert :ok = Cache.abort_sink(sink, :cancelled, cache: {SinkAbortErrorAdapter, []})

  assert_receive {:telemetry_event, [:image_plug, :cache, :tee, :stop], _measurements,
                  %{cache: :cleanup_error, error: :abort_failed, output_format: :webp}}
end
```

Use a small metadata helper in this test file:

```elixir
defp metadata do
  %Entry.Metadata{
    content_type: "image/webp",
    headers: [],
    created_at: ~U[2026-04-29 10:15:00Z],
    output_format: :webp
  }
end
```

- [ ] **Step 4: Add `Cache.put/3` compatibility tests through the sink**

Keep `Cache.put/3` only as a API helper:

```elixir
test "put writes through the sink callbacks" do
  assert :ok =
           Cache.put(cache_key(), entry("abcdef"),
             cache: {SinkMissAdapter, test_pid: self()}
           )

  assert_received {:write_chunk, "abcdef"}
  assert_received {:commit_sink, ["abcdef"]}
end

test "legacy put-only adapters are invalid cache configuration" do
  assert {:error, {:cache_read, {:invalid_cache_config, {:adapter, LegacyPutOnlyAdapter}}}} =
           Cache.lookup(
             conn(:get, "/_/f:webp/plain/images/cat.jpg"),
             plan(),
             source_identity(),
             cache: {LegacyPutOnlyAdapter, []}
           )
end
```

- [ ] **Step 5: Run cache API tests and verify failure**

Run:

```bash
mise exec -- mix test test/image_plug/cache_test.exs
```

Expected: FAIL because `Cache.open_sink/3`, `Cache.write_chunk/3`, `Cache.commit_sink/2`, `Cache.abort_sink/3`, `Entry.Metadata`, and `Cache.Sink` don't exist yet.

## Task 2: Add Filesystem Sink Tests

Prove atomic visibility and cleanup on the concrete adapter.

**Files:**
- Edit: `test/image_plug/cache/file_system_test.exs`

- [ ] **Step 1: Add metadata helper**

Add:

```elixir
defp entry_metadata(overrides \\ []) do
  struct!(
    ImagePlug.Cache.Entry.Metadata,
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
```

- [ ] **Step 2: Add streaming write and visibility tests**

Add:

```elixir
test "sink writes chunks to temp files and makes the entry visible only at commit", %{root: root} do
  cache_key = key("abcdef" <> String.duplicate("1", 58))

  assert {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), root: root)
  assert {:ok, state} = FileSystem.write_chunk(state, "encoded ", root: root)
  assert {:ok, state} = FileSystem.write_chunk(state, "image", root: root)

  assert FileSystem.get(cache_key, root: root) == :miss
  assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
  assert File.ls!(paths.dir) |> Enum.any?(&String.ends_with?(&1, ".tmp"))

  assert :ok = FileSystem.commit_sink(state, root: root)
  assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
  assert cached_entry.body == "encoded image"
  assert cached_entry.content_type == "image/webp"
  assert cached_entry.headers == [{"vary", "Accept"}]
  assert cached_entry.created_at == ~U[2026-04-29 10:15:00Z]
  refute File.ls!(paths.dir) |> Enum.any?(&String.ends_with?(&1, ".tmp"))
end
```

- [ ] **Step 3: Add abort cleanup tests**

Add:

```elixir
test "sink abort removes temp files and leaves no visible entry", %{root: root} do
  cache_key = key("bbbbbb" <> String.duplicate("1", 58))

  assert {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), root: root)
  assert {:ok, state} = FileSystem.write_chunk(state, "partial", root: root)
  assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
  assert File.ls!(paths.dir) |> Enum.any?(&String.ends_with?(&1, ".tmp"))

  assert :ok = FileSystem.abort_sink(state, root: root)
  assert FileSystem.get(cache_key, root: root) == :miss
  refute File.ls!(paths.dir) |> Enum.any?(&String.ends_with?(&1, ".tmp"))
end

test "commit failure removes temp files and doesn't expose metadata", %{root: root} do
  cache_key = key("cccccc" <> String.duplicate("1", 58))
  assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
  File.mkdir_p!(paths.dir)
  File.mkdir_p!(paths.meta_path)

  assert {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), root: root)
  assert {:ok, state} = FileSystem.write_chunk(state, "body", root: root)
  assert {:error, _reason} = FileSystem.commit_sink(state, root: root)

  refute match?({:hit, _entry}, FileSystem.get(cache_key, root: root))
  refute File.exists?(Path.join(paths.dir, body_filename(cache_key, "body")))
  refute File.ls!(paths.dir) |> Enum.any?(&String.ends_with?(&1, ".tmp"))
end

test "sink commit cleans up when temporary metadata write fails", %{root: root} do
  cache_key = key("cdcdcd" <> String.duplicate("1", 58))
  assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
  File.mkdir_p!(paths.dir)

  temp_obstruction = Path.join(paths.dir, ".#{cache_key.hash}.forced.tmp")
  File.mkdir_p!(temp_obstruction)

  assert {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), root: root)
  assert {:ok, state} = FileSystem.write_chunk(state, "body", root: root)

  assert {:error, _reason} =
           FileSystem.commit_sink(
             %{state | temp_meta_path: temp_obstruction},
             root: root
           )

  refute File.exists?(Path.join(paths.dir, body_filename(cache_key, "body")))
  refute File.ls!(paths.dir) |> Enum.any?(&String.ends_with?(&1, ".tmp"))
end

test "sink commit cleans up when body rename fails", %{root: root} do
  cache_key = key("cecece" <> String.duplicate("1", 58))
  assert {:ok, paths} = FileSystem.paths(cache_key, root: root)
  File.mkdir_p!(paths.dir)

  body_path = Path.join(paths.dir, body_filename(cache_key, "body"))
  File.mkdir_p!(body_path)

  assert {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), root: root)
  assert {:ok, state} = FileSystem.write_chunk(state, "body", root: root)

  assert {:error, _reason} = FileSystem.commit_sink(state, root: root)
  assert File.dir?(body_path)
  refute File.exists?(paths.meta_path)
  refute File.ls!(paths.dir) |> Enum.any?(&String.ends_with?(&1, ".tmp"))
end

test "concurrent sink commits for the same key leave a readable entry", %{root: root} do
  cache_key = key("dddddd" <> String.duplicate("1", 58))

  results =
    ["body-one", "body-two"]
    |> Enum.map(fn body ->
      Task.async(fn ->
        {:ok, state} = FileSystem.open_sink(cache_key, entry_metadata(), root: root)
        {:ok, state} = FileSystem.write_chunk(state, body, root: root)
        FileSystem.commit_sink(state, root: root)
      end)
    end)
    |> Enum.map(&Task.await(&1, 5_000))

  assert results == [:ok, :ok]
  assert {:hit, cached_entry} = FileSystem.get(cache_key, root: root)
  assert cached_entry.body in ["body-one", "body-two"]
end
```

- [ ] **Step 4: Run filesystem tests and verify failure**

Run:

```bash
mise exec -- mix test test/image_plug/cache/file_system_test.exs
```

Expected: FAIL because filesystem sink callbacks aren't implemented.

## Task 3: Implement Cache Sink API

Add the cache-owned sink data structures and public cache functions.

**Files:**
- Create: `lib/image_plug/cache/sink.ex`
- Create: `lib/image_plug/cache/entry/metadata.ex`
- Edit: `lib/image_plug/cache.ex`

- [ ] **Step 1: Add `ImagePlug.Cache.Entry.Metadata`**

Create `lib/image_plug/cache/entry/metadata.ex`:

```elixir
defmodule ImagePlug.Cache.Entry.Metadata do
  @moduledoc false

  alias ImagePlug.Cache.Entry

  @enforce_keys [:content_type, :headers, :created_at, :output_format]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          content_type: String.t(),
          headers: [Entry.header()],
          created_at: DateTime.t(),
          output_format: atom()
        }
end
```

- [ ] **Step 2: Add `ImagePlug.Cache.Sink`**

Create `lib/image_plug/cache/sink.ex`:

```elixir
defmodule ImagePlug.Cache.Sink do
  @moduledoc false

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key

  @enforce_keys [
    :adapter,
    :key,
    :adapter_opts,
    :metadata,
    :state,
    :size,
    :max_body_bytes,
    :output_format,
    :status
  ]
  defstruct @enforce_keys

  @type status :: :open | :dropped | :committed | :aborted

  @type t :: %__MODULE__{
          adapter: module(),
          key: Key.t(),
          adapter_opts: keyword(),
          metadata: Entry.Metadata.t(),
          state: term(),
          size: non_neg_integer(),
          max_body_bytes: non_neg_integer() | nil,
          output_format: atom(),
          status: status()
        }
end
```

- [ ] **Step 3: Extend the cache behaviour and boundary exports**

In `lib/image_plug/cache.ex`:

```elixir
alias ImagePlug.Cache.Sink
alias ImagePlug.Output.Format
alias ImagePlug.Output.Resolved
alias ImagePlug.Telemetry
```

Update the Boundary exports:

```elixir
exports: [
  Entry,
  Key,
  FileSystem
]
```

Don't export `Sink`; callers only use `ImagePlug.Cache.sink()`.

Replace the write callback with sink callbacks:

```elixir
@callback open_sink(Key.t(), Entry.Metadata.t(), keyword()) ::
            {:ok, state()} | {:error, term()}
@callback write_chunk(state(), binary(), keyword()) ::
            {:ok, state()} | {:error, term(), state()}
@callback commit_sink(state(), keyword()) :: :ok | {:error, term()}
@callback abort_sink(state(), keyword()) :: :ok | {:error, term()}
```

Add:

```elixir
@opaque sink :: Sink.t()
```

- [ ] **Step 4: Implement public sink API functions**

Add:

```elixir
@doc false
@spec open_sink(Key.t() | nil, Resolved.t(), keyword()) :: sink() | nil
def open_sink(nil, %Resolved{}, _opts), do: nil

def open_sink(%Key{} = key, %Resolved{} = resolved_output, opts) when is_list(opts) do
  with {:ok, adapter, cache_opts} <- cache_config(opts),
       {:ok, metadata} <- metadata(resolved_output) do
    do_open_sink(adapter, key, metadata, cache_opts)
  else
    nil -> nil
    {:error, reason} -> handle_sink_open_error(reason, opts)
  end
end

@doc false
@spec write_chunk(sink() | nil, binary(), keyword()) :: sink() | nil
def write_chunk(nil, _chunk, _opts), do: nil
def write_chunk(%Sink{status: status} = sink, _chunk, _opts) when status != :open, do: sink

def write_chunk(%Sink{} = sink, chunk, opts) when is_binary(chunk) do
  new_size = sink.size + byte_size(chunk)

  if too_large?(new_size, sink.max_body_bytes) do
    sink
    |> abort_adapter(:too_large, opts)
    |> emit_tee(:write_skipped, :too_large, nil, opts)

    nil
  else
    do_write_chunk(%{sink | size: new_size}, chunk, opts)
  end
end

@doc false
@spec commit_sink(sink() | nil, keyword()) :: :ok
def commit_sink(nil, _opts), do: :ok
def commit_sink(%Sink{status: status}, _opts) when status != :open, do: :ok
def commit_sink(%Sink{} = sink, opts), do: do_commit_sink(sink, opts)

@doc false
@spec abort_sink(sink() | nil, atom(), keyword()) :: :ok
def abort_sink(nil, _reason, _opts), do: :ok
def abort_sink(%Sink{status: status}, _reason, _opts) when status != :open, do: :ok
def abort_sink(%Sink{} = sink, reason, opts), do: do_abort_sink(sink, reason, opts)
```

Implement private helpers with these semantics:

```elixir
defp metadata(%Resolved{} = resolved_output) do
  with {:ok, headers} <- Entry.cacheable_headers(resolved_output.response_headers) do
    {:ok,
     %Entry.Metadata{
       content_type: Format.mime_type!(resolved_output.format),
       headers: headers,
       created_at: DateTime.utc_now(),
       output_format: resolved_output.format
     }}
  end
end
```

`do_open_sink/4` calls `adapter.open_sink/3` with normalized adapter options,
wraps the adapter state in `%Sink{adapter_opts: cache_opts}`, and logs then
returns `nil` for adapter errors or unexpected results.

`do_write_chunk/3` calls `adapter.write_chunk/3` with `sink.adapter_opts`; on
`{:ok, adapter_state}` it returns updated `%Sink{state: adapter_state}`; on
`{:error, reason, adapter_state}` it aborts once, emits `[:cache, :tee]` with
`cache: :write_error`, logs, and returns `nil`.

`do_commit_sink/2` wraps the adapter commit in:

```elixir
Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :write], %{}, fn ->
  result = sink.adapter.commit_sink(sink.state, sink.adapter_opts)
  {:ok, commit_stop_metadata(result, sink)}
end)
```

`do_abort_sink/3` calls adapter abort with `sink.adapter_opts` and emits
`[:cache, :tee]` with `cache: :abandoned` for normal abort reasons. If abort
fails, emit `cache: :cleanup_error`.

- [ ] **Step 5: Rewrite `Cache.put/3` through the sink API**

Keep the public return shape used by tests:

```elixir
@spec put(Key.t(), Entry.t(), keyword()) ::
        :ok | :skipped | {:ok, {:cache_write, term()}} | {:error, {:cache_write, term()}}
def put(%Key{} = key, %Entry{} = entry, opts) when is_list(opts) do
  case open_sink_for_entry(key, entry, opts) do
    nil -> :skipped
    %Sink{} = sink -> write_put_body(sink, entry.body, opts)
  end
end
```

Use private helpers that preserve `Entry.created_at` exactly. Don't rebuild
whole-body helper metadata from `Resolved`, because `Cache.put/3` callers
already supplied the entry timestamp:

```elixir
defp open_sink_for_entry(%Key{} = key, %Entry{} = entry, opts) do
  with {:ok, adapter, cache_opts} <- cache_config(opts),
       {:ok, format} <- Format.format(entry.content_type),
       {:ok, headers} <- Entry.cacheable_headers(entry.headers) do
    metadata = %Entry.Metadata{
      content_type: entry.content_type,
      headers: headers,
      created_at: entry.created_at,
      output_format: format
    }

    do_open_sink(adapter, key, metadata, cache_opts)
  else
    nil -> nil
    {:error, reason} -> handle_sink_open_error(reason, opts)
  end
end

defp write_put_body(%Sink{} = sink, body, opts) do
  case write_chunk(sink, body, opts) do
    nil -> :skipped
    %Sink{} = sink -> commit_put_sink(sink, opts)
  end
end
```

If `open_sink_for_entry/3` or `write_chunk/3` drops the sink because of
`max_body_bytes`, return `:skipped`. If adapter commit fails open, preserve the
existing whole-body helper return `{:ok, {:cache_write, reason}}` so current
cache tests can still assert the write failure reason. Prepared-stream delivery
must not use that return value.

- [ ] **Step 6: Update adapter validation**

Change `validate_adapter/1` so a cache adapter must export:

```elixir
get/2
open_sink/3
write_chunk/3
commit_sink/2
abort_sink/2
```

Don't require `put/3`.

- [ ] **Step 7: Run cache API tests**

Run:

```bash
mise exec -- mix test test/image_plug/cache_test.exs
```

Expected: PASS for cache API tests. If existing tests still mention `fail_on_cache_error`, remove those stale option assertions instead of preserving dead behavior.

## Task 4: Implement Filesystem Sink

Move filesystem writes from whole-body `put/3` to staged sink callbacks.

**Files:**
- Edit: `lib/image_plug/cache/file_system.ex`

- [ ] **Step 1: Add sink state and callbacks**

Add `open_sink/3`, `write_chunk/3`, `commit_sink/2`, and `abort_sink/2`.

Use this adapter state shape:

```elixir
%{
  paths: paths,
  temp_body_path: temp_body_path,
  temp_meta_path: nil,
  body_io: body_io,
  size: 0,
  hash_context: :crypto.hash_init(:sha256),
  metadata: metadata
}
```

`open_sink/3` must:

- call `paths/2`
- create `paths.dir`
- create a unique temp body path in `paths.dir`
- open the body file with `[:write, :binary, :exclusive]`

`write_chunk/3` must:

- call `IO.binwrite(body_io, chunk)`
- update `size`
- update `hash_context` with `:crypto.hash_update/2`
- return `{:error, reason, state}` on write failure with the current state

- [ ] **Step 2: Make commit write body first and metadata last**

`commit_sink/2` must:

1. close `body_io`
2. compute SHA-256 from `hash_context`
3. compute `body_filename(paths.hash, body_sha256)`
4. encode metadata with `body_byte_size`, `body_sha256`, and `body_filename`
5. write metadata to a unique temp metadata path in `paths.dir` with exclusive
   creation semantics
6. rename the body temp path to the content-addressed body path
7. rename metadata temp path to `paths.meta_path`

Readers discover entries through metadata, so metadata must become visible last.

If any commit step fails, close the body file if still open and remove temporary
files. If the body was newly renamed before metadata commit failed, remove that
body path. Don't remove an existing matching body created by another writer.

Preserve the current same-key writer behavior: if another writer already
committed the same content-addressed body, verify the existing body digest,
discard this writer's temp body, and continue to metadata commit. If the
existing body path is occupied by non-matching content or a directory, fail and
clean up this writer's temp files.

- [ ] **Step 3: Make abort idempotent**

`abort_sink/2` must close the body file if open and remove temp body and
metadata paths. Treat `:enoent` cleanup as success. Repeated adapter abort calls
with the same state must be harmless because the cache API returns `:ok` and
can't update an old caller-held sink value.

- [ ] **Step 4: Rewrite `put/3` or remove adapter `put/3`**

Remove `FileSystem.put/3` as a behaviour implementation. If keeping it as a local helper for compatibility inside tests, implement it through the new callbacks:

```elixir
def put(%Key{} = key, %Entry{} = entry, opts) when is_list(opts) do
  with {:ok, headers} <- Entry.cacheable_headers(entry.headers),
       {:ok, output_format} <- ImagePlug.Output.Format.format(entry.content_type) do
    metadata = %Entry.Metadata{
      content_type: entry.content_type,
      headers: headers,
      created_at: entry.created_at,
      output_format: output_format
    }

    with {:ok, state} <- open_sink(key, metadata, opts),
         {:ok, state} <- write_chunk(state, entry.body, opts) do
      commit_sink(state, opts)
    end
  end
end
```

Prefer removing adapter `put/3` if no test needs direct adapter calls after updating `Cache.put/3`.

- [ ] **Step 5: Run filesystem tests**

Run:

```bash
mise exec -- mix test test/image_plug/cache/file_system_test.exs
```

Expected: PASS.

## Task 5: Replace `SourceSession.CacheBuffer`

Change `SourceSession` to store an opaque cache sink.

**Files:**
- Edit: `lib/image_plug/request/source_session.ex`
- Delete: `lib/image_plug/request/source_session/cache_buffer.ex`
- Edit: `test/image_plug/request/source_session_test.exs`

- [ ] **Step 1: Update SourceSession tests for sink events**

Replace cache write probe modules in `test/image_plug/request/source_session_test.exs` with sink callbacks:

```elixir
defmodule CacheSinkProbe do
  def get(_key, _opts), do: :miss

  def open_sink(key, metadata, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:cache_open_sink, key, metadata})
    {:ok, %{chunks: [], opts: opts}}
  end

  def write_chunk(state, chunk, _opts) do
    send(Keyword.fetch!(state.opts, :test_pid), {:cache_write_chunk, chunk})
    {:ok, %{state | chunks: [chunk | state.chunks]}}
  end

  def commit_sink(state, _opts) do
    send(Keyword.fetch!(state.opts, :test_pid), {:cache_commit_sink, Enum.reverse(state.chunks)})
    :ok
  end

  def abort_sink(state, _opts) do
    send(Keyword.fetch!(state.opts, :test_pid), {:cache_abort_sink, Enum.reverse(state.chunks)})
    :ok
  end
end
```

Update assertions:

- before `:done`, assert no `{:cache_commit_sink, _}` has been received
- after `:done`, assert `{:cache_commit_sink, ["first chunk", "second chunk"]}`
- on cancellation, stream errors, owner death, first-chunk failure, and client close paths, assert abort events where a sink opened
- on size overflow, assert no commit and assert tee telemetry `cache: :write_skipped`

- [ ] **Step 2: Add filesystem-backed cleanup coverage**

Add one test that uses real `ImagePlug.Cache.FileSystem` and a controlled stream:

```elixir
test "filesystem sink removes temp files on explicit cancellation", context do
  register_stream_events!()
  root = Path.join(System.tmp_dir!(), "image_plug_source_session_sink_#{context.test}")
  File.rm_rf!(root)
  on_exit(fn -> File.rm_rf!(root) end)

  {:ok, session} =
    SourceSession.start(
      cached_request(
        opts: opts(
          image_module: CleanupStreamImage,
          cache: {ImagePlug.Cache.FileSystem, root: root}
        )
      )
    )

  assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
  assert :ok = SourceSession.cancel(session)
  assert_receive {:stream_finalized, :second}
  refute root |> Path.wildcard("**/*.tmp") |> Enum.any?()
end
```

Add similar filesystem tests for stream error and owner death if the cache API and filesystem adapter tests don't already cover the cleanup reason being exercised through `SourceSession`.

- [ ] **Step 3: Update `SourceSession` state and aliases**

In `lib/image_plug/request/source_session.ex`:

```elixir
alias ImagePlug.Cache
```

Remove:

```elixir
alias ImagePlug.Request.SourceSession.CacheBuffer
```

Change the struct field:

```elixir
:cache_sink,
```

Remove `:cache_buffer`.

- [ ] **Step 4: Open the sink before stream suspension can leak**

In `prepare_stream/1`, replace cache buffer setup with:

```elixir
cache_sink = Cache.open_sink(request.cache_key, resolved_output, request.opts)
state = %{state | cache_sink: cache_sink}
```

Keep this before creating or reducing the encoder stream. This is required so
encoder stream creation errors, empty streams, and first-chunk errors can abort
an opened sink through the existing failure cleanup path.

After first chunk:

```elixir
cache_sink = Cache.write_chunk(state.cache_sink, first_chunk, request.opts)
state = %{state | cache_sink: cache_sink}
```

Store `cache_sink` in state. Don't branch on `nil`; `nil` means caching is off.

- [ ] **Step 5: Write later chunks before returning them**

In `reduce_result/2`, replace `CacheBuffer.append/3` with:

```elixir
cache_sink = Cache.write_chunk(state.cache_sink, chunk, state.request.opts)

{{:chunk, chunk}, %{state | suspended: {chunk, continuation}, cache_sink: cache_sink}}
```

- [ ] **Step 6: Commit only on normal completion**

In `finish_stream/1`, replace commit with:

```elixir
_result = Cache.commit_sink(state.cache_sink, state.request.opts)
{:done, %{state | suspended: nil, cache_sink: nil}}
```

Keep the pending owner/control-message check before commit.

- [ ] **Step 7: Halt before aborting the sink**

Change shutdown cleanup ordering so the encoder continuation is halted before the sink aborts.

Use:

```elixir
defp shutdown_halt_stream(state, reason \\ :cancelled) do
  case halt_stream(state) do
    {:ok, state} ->
      abort_cache_sink(state, reason)

    {:error, cancel_reason, state} ->
      state
      |> abort_cache_sink(reason)
      |> mark_failed({:cancel, cancel_reason})
  end
end
```

For explicit cancel:

```elixir
case halt_stream(%{state | phase: :cancelled}) do
  {:ok, state} ->
    state = abort_cache_sink(state, :cancelled)
    {:stop, :normal, :ok, state}

  {:error, reason, state} ->
    state = abort_cache_sink(state, :cancelled)
    {:stop, {:shutdown, {:cancel_failed, reason}}, {:error, {:cancel, reason}}, state}
end
```

Add:

```elixir
defp abort_cache_sink(%{cache_sink: cache_sink, request: request} = state, reason) do
  _result = Cache.abort_sink(cache_sink, reason, request.opts)
  %{state | cache_sink: nil}
end
```

This order is non-negotiable: halt the Vix stream first, then abort cache staging.

For `next_chunk/1` errors, the continuation has already been cleared by the
error path before `reduce_result/2` returns. Route that branch through
`abort_cache_sink/2`, not `shutdown_halt_stream/2`, and keep a short comment in
the implementation explaining that there is no suspended continuation left to
halt.

- [ ] **Step 8: Remove `SourceSession.CacheBuffer`**

Delete:

```bash
mise exec -- git rm lib/image_plug/request/source_session/cache_buffer.ex
```

Run:

```bash
rg "CacheBuffer|cache_buffer" lib test
```

Expected: no runtime references. Historical docs may still mention earlier slices.

- [ ] **Step 9: Run SourceSession tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs
```

Expected: PASS.

## Task 6: Update Request, Telemetry, and Architecture Tests

Remove stale assumptions about `Cache.put/3` and the old buffer.

**Files:**
- Edit: `test/image_plug/request_runner_test.exs`
- Edit: `test/image_plug_test.exs`
- Edit: `test/image_plug/telemetry_test.exs`
- Edit: `test/image_plug/architecture_boundary_test.exs`
- Edit: `test/support/image_plug/imgproxy_wire_conformance_test/cache_probe.ex`
- Edit: `test/support/image_plug/request_safety_test/cache_probe.ex`

- [ ] **Step 1: Update cache probe modules to sink callbacks**

Every configured test cache adapter must implement the full sink contract after
this slice, including hit-only and "shouldn't write" probes. A valid test
adapter needs `get/2`, `open_sink/3`, `write_chunk/3`, `commit_sink/2`, and
`abort_sink/2`. Replace `put/3` with:

```elixir
def open_sink(_key, _metadata, opts), do: {:ok, %{opts: opts, chunks: []}}
def write_chunk(state, chunk, _opts), do: {:ok, %{state | chunks: [chunk | state.chunks]}}
def commit_sink(_state, _opts), do: :ok
def abort_sink(_state, _opts), do: :ok
```

If a probe needs to assert writes, send events from `write_chunk/3` or
`commit_sink/2`, not from `put/3`. If a probe represents a cache hit and should
not write, implement sink callbacks that raise with a clear test message so
unexpected writes still fail loudly.

Remove stale runtime tests that describe `fail_on_cache_error` as accepted or
meaningful. After `b15642d`, runtime cache errors fail open. Keep only tests
that prove unknown adapter options such as `fail_on_cache_error` are rejected
by configuration validation.

- [ ] **Step 2: Update telemetry assertions**

Keep existing cache lookup telemetry. Update cache write tests to assert sink commit telemetry:

```elixir
assert_event(events, [:image_plug, :cache, :write, :stop], fn _measurements, metadata ->
  metadata.cache == :write and metadata.result == :ok
end)
```

For runtime sink errors, assert:

```elixir
%{result: :cache_error, cache: :write_error, error: reason}
```

For abandoned or oversize staging, assert `[:image_plug, :cache, :tee, :stop]`.

- [ ] **Step 3: Strengthen architecture tests**

Update `"response delivery stays unaware of source sessions and cache teeing"` forbidden terms:

```elixir
forbidden_terms = [
  "ImagePlug.Request.SourceSession",
  "ImagePlug.Request.SourceSessionSupervisor",
  "ImagePlug.Cache.Sink",
  "Cache.open_sink",
  "Cache.write_chunk",
  "Cache.commit_sink",
  "Cache.abort_sink",
  "Cache.put",
  "SourceSession.CacheBuffer"
]
```

Add a cache boundary assertion that request code doesn't name `ImagePlug.Cache.Sink`:

```elixir
test "request code treats cache sinks as opaque cache values" do
  request_sources =
    "lib/image_plug/request/**/*.ex"
    |> Path.wildcard()
    |> Map.new(fn file -> {file, File.read!(file)} end)

  forbidden_terms = [
    "ImagePlug.Cache.Sink",
    "Cache.Sink",
    ".Sink",
    "%Sink{",
    "%ImagePlug.Cache.Sink{"
  ]

  violations =
    for {file, source} <- request_sources,
        term <- forbidden_terms,
        String.contains?(source, term) do
      "#{file} must not inspect cache sink internals through #{term}"
    end

  assert violations == []
end
```

Keep this test focused on boundary ownership. Don't add tests that only memorialize stale deleted modules.

- [ ] **Step 4: Run focused non-Vix tests**

Run:

```bash
mise exec -- mix test test/image_plug/cache_test.exs test/image_plug/cache/file_system_test.exs test/image_plug/telemetry_test.exs test/image_plug/architecture_boundary_test.exs
```

Expected: PASS.

- [ ] **Step 5: Run focused Vix/request tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs test/image_plug/request_runner_test.exs test/image_plug/response_sender_test.exs
```

Expected: PASS. `Response.Sender` tests shouldn't need production code changes.

## Task 7: Stop Criteria and Review

Verify the slice before committing implementation.

**Files:**
- Read: `docs/superpowers/designs/2026-05-23-transactional-cache-sink.md`
- Read/Edit if review requires: files changed by Tasks 3-6

- [ ] **Step 1: Run stop-criteria checks**

Run:

```bash
rg "SourceSession.CacheBuffer|cache_buffer|CacheBuffer" lib test
```

Expected: no matches in runtime code or current tests.

Run:

```bash
rg "fail_on_cache_error" lib test
```

Expected: matches only in tests asserting the stale option is rejected as an
unknown cache option, or no matches if those tests are removed as unnecessary.

Run:

```bash
rg "Cache\\.put|Cache\\.open_sink|Cache\\.write_chunk|Cache\\.commit_sink|Cache\\.abort_sink|ImagePlug\\.Cache\\.Sink" lib/image_plug/response test/image_plug/response_sender_test.exs
```

Expected: no matches in response delivery code or response sender tests except comments that are removed before commit.

Run:

```bash
rg "\\{:image,|:image," lib/image_plug/request lib/image_plug/response test/image_plug/request_runner_test.exs test/image_plug/response_sender_test.exs
```

Expected: no delivery-shape matches. Ignore an unrelated output negotiation
atom only after manually confirming the match isn't a delivery shape.

- [ ] **Step 2: Run full focused verification**

Run:

```bash
mise exec -- mix test test/image_plug/cache_test.exs test/image_plug/cache/file_system_test.exs test/image_plug/telemetry_test.exs test/image_plug/architecture_boundary_test.exs
```

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs test/image_plug/request_runner_test.exs test/image_plug/response_sender_test.exs
```

Run the full suite before commit because the adapter behaviour contract changes
test support modules outside the focused files:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test
```

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix compile --warnings-as-errors
```

- [ ] **Step 3: Run the required parallel subagent review cycle**

Dispatch four reviewers in parallel:

1. **Cache correctness and atomic visibility**
   - Review `ImagePlug.Cache`, `ImagePlug.Cache.Sink`, `ImagePlug.Cache.Entry.Metadata`, cache telemetry, and `Cache.put/3`.
   - Check that no visible entry exists before commit, size-limit drops don't write cache, and runtime errors fail open.

2. **SourceSession lifecycle and cleanup ordering**
   - Review `ImagePlug.Request.SourceSession`.
   - Check halt-before-abort ordering, owner death, cancellation, stream errors, normal completion, and idempotent cleanup assumptions.

3. **Filesystem adapter and sink API design**
   - Review `ImagePlug.Cache.FileSystem`.
   - Check temp file path safety, metadata-last commit, concurrent writers, body rollback, and cleanup on abort/commit failure.

4. **Test quality and architecture boundaries**
   - Review changed tests and boundary assertions.
   - Check that tests assert behavior rather than private helper names, response delivery stays cache-unaware, and no old direct image delivery path was restored.

- [ ] **Step 4: Apply accepted review feedback**

Apply only feedback that preserves the design constraints:

- accept fixes that improve cache atomicity, fail-open behavior, cleanup ordering, or boundary ownership
- reject suggestions to put cache knowledge in `Response.Sender`
- reject suggestions to add S3 support in this slice
- reject suggestions to add cache writer GenServers in this slice
- reject suggestions to preserve `SourceSession.CacheBuffer`
- reject suggestions to restore sender-side image encoding

- [ ] **Step 5: Rerun verification after accepted fixes**

Rerun every command from Step 2.

- [ ] **Step 6: Format and commit**

Run:

```bash
mise exec -- mix format
```

Run the focused verification again if formatting changed code.

Commit:

```bash
mise exec -- git add lib test
mise exec -- git commit -m "Add transactional cache sink"
```

Push only if requested by the current instruction set:

```bash
mise exec -- git push
```

## Plan Review Checklist

- Tests are written before implementation tasks.
- `Response.Sender` doesn't change.
- `SourceSession` stores only `nil | Cache.sink()`.
- Cache sink internals stay inside the cache boundary.
- Filesystem entries become visible by metadata commit only.
- Runtime cache sink failures fail open.
- `:max_body_bytes` is a cache staging limit, not a response delivery limit.
- `SourceSession.CacheBuffer` is deleted.
- `Cache.put/3` is sink-backed or removed from live request paths.
- No S3 implementation is included.
- No direct image response path is restored.
