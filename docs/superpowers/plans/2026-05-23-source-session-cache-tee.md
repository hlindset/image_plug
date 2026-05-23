# SourceSession Cache Tee Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans for this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move configured cache misses onto supervised prepared streams while `SourceSession` owns bounded cache buffering and cache writes.

**Architecture:** This is Slice 5 only. `ImagePlug.Request.SourceSession` tees encoded chunks into a private cache buffer as it prepares and resumes the lazy encoder stream. `ImagePlug.Response.Sender` stays unaware of cache internals. It sends `first_chunk`, calls `next/0` after each successful socket write, and calls `cancel/0` on delivery failure. Cache commit happens inside `SourceSession.next/1` when the stream reaches `:done`, after the sender has delivered every chunk returned by the session.

**Tech Stack:** Elixir, OTP `GenServer`, supervised `DynamicSupervisor` sessions, `Enumerable.reduce/3` suspension, Plug chunked responses, ExUnit, Boundary, pinned Vix fork `3a30758d44526d3c914b2076bd0be201c972f2b7`, `mise exec -- mix`.

---

## Preconditions

Slice 4 landed in `2c9206a Add prepared stream routing`.

`mix.exs` must keep Vix pinned to:

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

Don't start Slice 6 from this plan. Slice 5 ends after cache teeing implementation, focused verification, and the required parallel review cycle. After accepted fixes, run Vale if docs change, commit, push if requested, and stop before public contract docs.

## Files

- Create: `lib/image_plug/request/source_session/cache_buffer.ex`
- Edit: `lib/image_plug/request/source_session/request.ex`
- Edit: `lib/image_plug/request/source_session.ex`
- Edit: `lib/image_plug/request/runner.ex`
- Edit: `test/image_plug/request/source_session_test.exs`
- Edit: `test/image_plug/request_runner_test.exs`
- Edit: `test/image_plug/architecture_boundary_test.exs`
- Read as needed: `lib/image_plug/cache.ex`
- Read as needed: `lib/image_plug/cache/entry.ex`
- Read as needed: `lib/image_plug/cache/key.ex`
- Read as needed: `lib/image_plug/response/sender.ex`
- Read as needed: `test/image_plug/response_sender_test.exs`
- Read as needed: `docs/superpowers/designs/2026-05-21-source-session-lifecycle-boundary.md`
- Read as needed: `docs/superpowers/plans/2026-05-23-prepared-stream-routing.md`

## Non-Goals

- Don't add public docs.
- Don't change `ImagePlug.Response.PreparedStream` unless a test proves the current `next` and `cancel` callbacks can't express the cache contract.
- Don't make `ImagePlug.Response.Sender` know about cache keys, entries, buffers, or writes.
- Don't stream cacheable misses when `fail_on_cache_error: true`; keep those on the existing pre-response full encode/cache path.
- Don't remove `ImagePlug.Request.SourceStreamBoundary` in this slice. The fail-closed cache miss path still uses it.
- Don't remove the existing `{:image, state, resolved_output, response}` delivery shape.
- Don't add `:gen_statem`.
- Don't add public cache tee configuration.

## Contracts

The routing table after this slice must be:

| Case | Route |
| --- | --- |
| cache hit with valid delivery headers | existing `{:cache_entry, entry, response}` delivery |
| no configured cache | supervised `SourceSession` and `Response.PreparedStream`, no cache buffer |
| resolved source has `cache: :skip` | supervised `SourceSession` and `Response.PreparedStream`, no cache lookup or write |
| configured cache miss with default fail-open cache errors | supervised `SourceSession` and `Response.PreparedStream` with cache tee |
| configured cache read error with fail-open miss | supervised `SourceSession` and `Response.PreparedStream` with cache tee using the computed key |
| configured cache miss with `fail_on_cache_error: true` | existing pre-response full encode/cache path |
| configured cache read error with `fail_on_cache_error: true` | existing cache error path |
| cache hit delivery validation failure with fail-open cache errors | supervised `SourceSession` and `Response.PreparedStream` with cache tee using the computed key |
| cache hit delivery validation failure with `fail_on_cache_error: true` | existing cache error path |

`SourceSession` owns all cache buffering for prepared streams. It must include `first_chunk` in the buffer during `prepare/1` and append each later chunk before returning it from `next/1`.

Cache commit may happen only when `SourceSession.next/1` reaches `:done`. That's the point where:

- the encoder stream completed,
- the sender has called `next/0` only after delivering every returned chunk,
- and the session can stop normally after emitting cache write telemetry.

Cache commit must not happen for:

- prepare failures,
- empty encoder streams,
- post-first-chunk source/decode/output/encode failures,
- sender cancellation after client close,
- owner death,
- explicit cancellation,
- incomplete streams,
- cache buffers dropped because appended chunks crossed `max_body_bytes`.

Cache write errors after headers commit fail open. They should emit cache write telemetry and allow `SourceSession.next/1` to return `:done`.

Cache body limit behavior is bounded:

- if appending a chunk would make the buffered body exceed `Cache.max_body_bytes(opts)`, drop the chunk list and mark the buffer as dropped,
- continue response delivery,
- don't write a cache entry,
- emit tee telemetry once with `cache: :write_skipped` and `reason: :too_large`.

The cache tee must use existing cache key data. Don't change cache key schema versions for this greenfield internal change.

## Telemetry

Keep telemetry low-cardinality and product-neutral.

Use existing cache write span shape for cache writes:

```elixir
[:image_plug, :cache, :write, :start]
[:image_plug, :cache, :write, :stop]
```

Stop metadata for streamed cache writes:

```elixir
%{result: :ok, cache: :write, output_format: format}
%{result: :cache_error, cache: :write_error, error: ImagePlug.Telemetry.error(error), output_format: format}
```

Add a cache tee span for buffer state changes that don't call the cache adapter:

```elixir
[:image_plug, :cache, :tee, :start]
[:image_plug, :cache, :tee, :stop]
```

Stop metadata:

```elixir
%{result: :ok, cache: :write_skipped, reason: :too_large, output_format: format}
%{result: :ok, cache: :abandoned, reason: :cancelled, output_format: format}
%{result: :ok, cache: :abandoned, reason: :stream_error, output_format: format}
%{result: :ok, cache: :abandoned, reason: :owner_down, output_format: format}
```

Don't emit full request paths, source URLs, filenames, cache keys, adapter module names, parser structs, transform internals, or raw exceptions in telemetry metadata.

## Task 1: Add SourceSession Cache Buffer Tests

Prove the protocol-level cache behavior before changing routing. Use test image modules that return small deterministic chunks so cache body assertions stay cheap.

**Files:**
- Edit: `test/image_plug/request/source_session_test.exs`

- [ ] **Step 1: Add cache aliases and test helpers**

Edit the alias block near the top of `test/image_plug/request/source_session_test.exs`:

```elixir
alias ImagePlug.Cache.Entry
alias ImagePlug.Cache.Key
```

Add these test modules after `MultiChunkImage`:

```elixir
defmodule SmallChunkImage do
  def stream!(_image, suffix: ".jpg"), do: ["abc", "def"]
end

defmodule CacheWriteProbe do
  def get(_key, _opts), do: :miss

  def put(key, %ImagePlug.Cache.Entry{} = entry, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:cache_put, key, entry, opts})
    :ok
  end
end

defmodule CacheWriteErrorProbe do
  def get(_key, _opts), do: :miss

  def put(_key, %ImagePlug.Cache.Entry{}, opts) do
    send(Keyword.fetch!(opts, :test_pid), :cache_put_attempted)
    {:error, :write_failed}
  end
end

defmodule OwnerDownBeforeDoneImage do
  @event_target ImagePlug.Request.SourceSessionTest.StreamEvents

  def stream!(_image, suffix: ".jpg") do
    Stream.resource(
      fn -> :first end,
      fn
        :first ->
          {["first chunk"], :finish}

        :finish ->
          if target = Process.whereis(@event_target) do
            send(target, {:before_stream_done, self()})
          end

          receive do
            :continue_stream_done -> {[], :done}
          end

        :done ->
          {:halt, :done}
      end,
      fn state ->
        if target = Process.whereis(@event_target) do
          send(target, {:owner_down_stream_finalized, state})
        end
      end
    )
  end
end
```

Replace the existing `request/1` helper so tests can opt into a cache key, then add the cache helpers near the bottom of the test file:

```elixir
defp request(overrides \\ []) do
  %Request{
    plan: Keyword.get(overrides, :plan, plan()),
    resolved_source: Keyword.get(overrides, :resolved_source, resolved_source()),
    output_policy: Keyword.get(overrides, :output_policy, output_policy()),
    opts: Keyword.get(overrides, :opts, opts()),
    cache_key: Keyword.get(overrides, :cache_key)
  }
end

defp cache_key do
  serialized_data = Key.serialize_key_data(source_identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]])

  %Key{
    hash: "test-cache-key",
    data: [source_identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]]],
    serialized_data: serialized_data
  }
end

defp cache_opts(adapter, extra_opts \\ []) do
  [
    cache: {adapter, Keyword.merge([test_pid: self()], extra_opts)}
  ]
end

defp cached_request(extra_opts \\ []) do
  request(
    cache_key: Keyword.get(extra_opts, :cache_key, cache_key()),
    opts:
      opts()
      |> Keyword.merge(cache_opts(Keyword.get(extra_opts, :adapter, CacheWriteProbe), Keyword.get(extra_opts, :cache_opts, [])))
      |> Keyword.merge(Keyword.get(extra_opts, :opts, []))
  )
end
```

- [ ] **Step 2: Add protocol tests for successful streamed cache writes**

Append these tests:

```elixir
test "cache tee writes buffered chunks only after next reaches done" do
  attach_telemetry([[:image_plug, :cache, :write, :stop]])

  key = cache_key()
  {:ok, session} = SourceSession.start(cached_request(cache_key: key))

  assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
  refute_received {:cache_put, _key, _entry, _opts}

  assert {:chunk, "second chunk"} = SourceSession.next(session)
  refute_received {:cache_put, _key, _entry, _opts}

  assert :done = SourceSession.next(session)

  assert_received {:cache_put, ^key,
                   %Entry{
                     body: "first chunksecond chunk",
                     content_type: "image/jpeg",
                     headers: [],
                     created_at: %DateTime{}
                   }, _opts}

  assert_receive {:telemetry_event, [:image_plug, :cache, :write, :stop], _measurements,
                  %{result: :ok, cache: :write, output_format: :jpeg}}
end
```

- [ ] **Step 3: Add body-limit drop coverage**

Append this test:

```elixir
test "cache tee drops buffering when the cache body limit is crossed" do
  attach_telemetry([[:image_plug, :cache, :tee, :stop]])

  {:ok, session} =
    SourceSession.start(
      cached_request(
        opts: opts(image_module: SmallChunkImage),
        cache_opts: [max_body_bytes: 5]
      )
    )

  assert {:ok, %Prepared{first_chunk: "abc"}} = SourceSession.prepare(session)
  assert {:chunk, "def"} = SourceSession.next(session)
  assert :done = SourceSession.next(session)

  refute_received {:cache_put, _key, _entry, _opts}

  assert_receive {:telemetry_event, [:image_plug, :cache, :tee, :stop], _measurements,
                  %{
                    result: :ok,
                    cache: :write_skipped,
                    reason: :too_large,
                    output_format: :jpeg
                  }}
end
```

- [ ] **Step 4: Add abandoned-buffer coverage**

Append these tests:

```elixir
test "cache tee abandons buffered chunks on explicit cancellation" do
  register_stream_events!()
  attach_telemetry([[:image_plug, :cache, :tee, :stop]])

  {:ok, session} =
    SourceSession.start(
      cached_request(opts: opts(image_module: CleanupStreamImage))
    )

  assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
  assert :ok = SourceSession.cancel(session)

  refute_received {:cache_put, _key, _entry, _opts}
  assert_receive {:stream_finalized, :second}

  assert_receive {:telemetry_event, [:image_plug, :cache, :tee, :stop], _measurements,
                  %{result: :ok, cache: :abandoned, reason: :cancelled, output_format: :jpeg}}
  refute_received {:telemetry_event, [:image_plug, :cache, :tee, :stop], _measurements,
                   %{cache: :abandoned}}
end

test "cache tee abandons buffered chunks on post-first-chunk stream errors" do
  register_stream_events!()
  attach_telemetry([[:image_plug, :cache, :tee, :stop]])

  {:ok, session} =
    SourceSession.start(
      cached_request(opts: opts(image_module: RaisingAfterFirstChunkImage))
    )

  assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

  assert {:error, {:encode, %RuntimeError{message: "boom after first chunk"}, stacktrace}} =
           SourceSession.next(session)

  assert is_list(stacktrace)
  refute_received {:cache_put, _key, _entry, _opts}
  assert_receive {:raising_stream_finalized, :raise}

  assert_receive {:telemetry_event, [:image_plug, :cache, :tee, :stop], _measurements,
                  %{result: :ok, cache: :abandoned, reason: :stream_error, output_format: :jpeg}}
  refute_received {:telemetry_event, [:image_plug, :cache, :tee, :stop], _measurements,
                   %{cache: :abandoned}}
end

test "cache tee abandons buffered chunks on owner death" do
  register_stream_events!()
  attach_telemetry([[:image_plug, :cache, :tee, :stop]])

  owner =
    spawn(fn ->
      receive do
        :stop_owner -> :ok
      end
    end)

  {:ok, session} =
    SourceSession.start(
      cached_request(opts: opts(image_module: CleanupStreamImage)),
      owner: owner,
      parent: self()
    )

  session_ref = Process.monitor(session)
  owner_ref = Process.monitor(owner)

  assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
  send(owner, :stop_owner)

  assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
  assert_receive {:stream_finalized, :second}
  assert_receive {:DOWN, ^session_ref, :process, ^session, {:shutdown, {:owner_down, :normal}}}
  refute_received {:cache_put, _key, _entry, _opts}

  assert_receive {:telemetry_event, [:image_plug, :cache, :tee, :stop], _measurements,
                  %{result: :ok, cache: :abandoned, reason: :owner_down, output_format: :jpeg}}
  refute_received {:telemetry_event, [:image_plug, :cache, :tee, :stop], _measurements,
                   %{cache: :abandoned}}
end

test "cache tee checks pending owner death before committing at done" do
  register_stream_events!()
  attach_telemetry([[:image_plug, :cache, :tee, :stop]])

  owner =
    spawn(fn ->
      receive do
        :stop_owner -> :ok
      end
    end)

  {:ok, session} =
    SourceSession.start(
      cached_request(opts: opts(image_module: OwnerDownBeforeDoneImage)),
      owner: owner,
      parent: self()
    )

  session_ref = Process.monitor(session)
  owner_ref = Process.monitor(owner)

  assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)

  parent = self()

  caller =
    spawn(fn ->
      send(parent, {:next_result, SourceSession.next(session)})
    end)

  caller_ref = Process.monitor(caller)

  assert_receive {:before_stream_done, ^session}
  send(owner, :stop_owner)
  assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
  send(session, :continue_stream_done)

  assert_receive {:next_result, {:error, {:session, {:shutdown, {:owner_down, :normal}}}}}
  assert_receive {:owner_down_stream_finalized, :done}
  assert_receive {:DOWN, ^caller_ref, :process, ^caller, :normal}
  assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}
  refute_received {:cache_put, _key, _entry, _opts}

  assert_receive {:telemetry_event, [:image_plug, :cache, :tee, :stop], _measurements,
                  %{result: :ok, cache: :abandoned, reason: :owner_down, output_format: :jpeg}}
end
```

- [ ] **Step 5: Add cache write fail-open coverage**

Append this test:

```elixir
test "cache tee write errors fail open after stream completion" do
  attach_telemetry([[:image_plug, :cache, :write, :stop]])

  {:ok, session} =
    SourceSession.start(
      cached_request(adapter: CacheWriteErrorProbe)
    )

  assert {:ok, %Prepared{first_chunk: "first chunk"}} = SourceSession.prepare(session)
  assert {:chunk, "second chunk"} = SourceSession.next(session)
  assert :done = SourceSession.next(session)

  assert_received :cache_put_attempted

  assert_receive {:telemetry_event, [:image_plug, :cache, :write, :stop], _measurements,
                  %{
                    result: :cache_error,
                    cache: :write_error,
                    error: :write_failed,
                    output_format: :jpeg
                  }}
end
```

- [ ] **Step 6: Add telemetry helper if missing**

If `test/image_plug/request/source_session_test.exs` doesn't already have telemetry helpers, add these near the bottom:

```elixir
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
```

- [ ] **Step 7: Run the protocol tests and verify they fail**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs
```

Expected: FAIL because `Request` has no `:cache_key`, `SourceSession` has no cache buffer, and code doesn't emit telemetry yet.

## Task 2: Add Private CacheBuffer State

Add a small request-private module that owns bounded chunk collection and cache entry construction. Keep it under `ImagePlug.Request.SourceSession` so it stays private to the session lifecycle.

**Files:**
- Create: `lib/image_plug/request/source_session/cache_buffer.ex`

- [ ] **Step 1: Add the CacheBuffer module**

Create `lib/image_plug/request/source_session/cache_buffer.ex`:

```elixir
defmodule ImagePlug.Request.SourceSession.CacheBuffer do
  @moduledoc false

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Telemetry

  @enforce_keys [:key, :content_type, :headers, :output_format]
  defstruct @enforce_keys ++
              [
                chunks: [],
                size: 0,
                max_body_bytes: nil,
                status: :collecting,
                emitted_drop?: false
              ]

  @type status :: :collecting | :dropped

  @type t :: %__MODULE__{
          key: Key.t(),
          content_type: String.t(),
          headers: [Entry.header()],
          output_format: atom(),
          chunks: [binary()],
          size: non_neg_integer(),
          max_body_bytes: non_neg_integer() | nil,
          status: status(),
          emitted_drop?: boolean()
        }

  @spec new(Key.t() | nil, Resolved.t(), keyword()) :: {:ok, t() | nil} | {:error, term()}
  def new(nil, %Resolved{}, _opts), do: {:ok, nil}

  def new(%Key{} = key, %Resolved{} = resolved_output, opts) do
    case Entry.cacheable_headers(resolved_output.response_headers) do
      {:ok, headers} ->
        {:ok,
         %__MODULE__{
           key: key,
           content_type: ImagePlug.Output.Format.mime_type!(resolved_output.format),
           headers: headers,
           output_format: resolved_output.format,
           max_body_bytes: Cache.max_body_bytes(opts)
         }}

      {:error, reason} ->
        {:error, {:invalid_cache_headers, reason}}
    end
  end

  @spec append(t() | nil, binary(), keyword()) :: t() | nil
  def append(nil, _chunk, _opts), do: nil
  def append(%__MODULE__{status: :dropped} = buffer, _chunk, _opts), do: buffer

  def append(%__MODULE__{} = buffer, chunk, opts) when is_binary(chunk) do
    size = buffer.size + byte_size(chunk)

    if too_large?(size, buffer.max_body_bytes) do
      buffer
      |> drop()
      |> emit_drop_once(opts)
    else
      %{buffer | chunks: [chunk | buffer.chunks], size: size}
    end
  end

  @spec commit(t() | nil, keyword()) :: :ok
  def commit(nil, _opts), do: :ok
  def commit(%__MODULE__{status: :dropped}, _opts), do: :ok

  def commit(%__MODULE__{status: :collecting} = buffer, opts) do
    entry = %Entry{
      body: buffer.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
      content_type: buffer.content_type,
      headers: buffer.headers,
      created_at: DateTime.utc_now()
    }

    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :write], %{}, fn ->
      result = Cache.put(buffer.key, entry, opts)
      {:ok, write_stop_metadata(result, buffer)}
    end)

    :ok
  end

  @spec abandon(t() | nil, atom(), keyword()) :: :ok
  def abandon(nil, _reason, _opts), do: :ok
  def abandon(%__MODULE__{status: :dropped}, _reason, _opts), do: :ok

  def abandon(%__MODULE__{} = buffer, reason, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :tee], %{}, fn ->
      {:ok,
       %{
         result: :ok,
         cache: :abandoned,
         reason: reason,
         output_format: buffer.output_format
       }}
    end)

    :ok
  end

  defp too_large?(_size, nil), do: false
  defp too_large?(size, max_body_bytes), do: size > max_body_bytes

  defp drop(%__MODULE__{} = buffer),
    do: %{buffer | status: :dropped, chunks: [], size: 0}

  defp emit_drop_once(%__MODULE__{emitted_drop?: true} = buffer, _opts), do: buffer

  defp emit_drop_once(%__MODULE__{} = buffer, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :tee], %{}, fn ->
      {:ok,
       %{
         result: :ok,
         cache: :write_skipped,
         reason: :too_large,
         output_format: buffer.output_format
       }}
    end)

    %{buffer | emitted_drop?: true}
  end

  defp write_stop_metadata(:ok, %__MODULE__{} = buffer),
    do: %{result: :ok, cache: :write, output_format: buffer.output_format}

  defp write_stop_metadata(:skipped, %__MODULE__{} = buffer),
    do: %{result: :ok, cache: :write_skipped, output_format: buffer.output_format}

  defp write_stop_metadata({:ok, {:cache_write, error}}, %__MODULE__{} = buffer),
    do: %{
      result: :cache_error,
      cache: :write_error,
      error: Telemetry.error(error),
      output_format: buffer.output_format
    }

  defp write_stop_metadata({:error, {:cache_write, error}}, %__MODULE__{} = buffer),
    do: %{
      result: :cache_error,
      cache: :write_error,
      error: Telemetry.error(error),
      output_format: buffer.output_format
    }
end
```

- [ ] **Step 2: Format the new module**

Run:

```bash
mise exec -- mix format lib/image_plug/request/source_session/cache_buffer.ex
```

Expected: formatter succeeds.

## Task 3: Teach SourceSession To Own Cache Tee State

Add the cache key to the request struct, append chunks during prepare and next, commit on `:done`, and abandon on every cleanup path.

**Files:**
- Edit: `lib/image_plug/request/source_session/request.ex`
- Edit: `lib/image_plug/request/source_session.ex`

- [ ] **Step 1: Add cache key to the request struct**

Edit `lib/image_plug/request/source_session/request.ex`:

```elixir
defmodule ImagePlug.Request.SourceSession.Request do
  @moduledoc false

  alias ImagePlug.Cache.Key
  alias ImagePlug.Output.Policy
  alias ImagePlug.Plan
  alias ImagePlug.Source

  @enforce_keys [:plan, :resolved_source, :output_policy, :opts]
  defstruct @enforce_keys ++ [cache_key: nil]

  @type t() :: %__MODULE__{
          plan: Plan.t(),
          resolved_source: Source.Resolved.t(),
          output_policy: Policy.t(),
          opts: keyword(),
          cache_key: Key.t() | nil
        }
end
```

- [ ] **Step 2: Add cache buffer state and alias**

Edit `lib/image_plug/request/source_session.ex`.

Add the alias:

```elixir
alias ImagePlug.Request.SourceSession.CacheBuffer
```

Add the field to `defstruct`:

```elixir
:cache_buffer,
```

- [ ] **Step 3: Initialize and seed the cache buffer during prepare**

In `prepare_stream/1`, initialize the cache buffer after output resolution and before creating or reducing the stream. `CacheBuffer.new/3` only needs `resolved_output`, the cache key, and opts. Keeping it before `first_chunk/1` prevents a fallible cache-header check from leaking a suspended encoder continuation.

```elixir
with {:ok, %Decoded{} = decoded} <-
       fetch_decode_validate_source(
         request.plan,
         request.resolved_source,
         request.opts,
         state.parent
       ),
     {:ok, %State{} = final_state} <-
       Processor.process_decoded_source(decoded, request.plan, request.opts),
     {:ok, %Resolved{} = resolved_output} <-
       resolve_output(request.output_policy, decoded.source_format, final_state.image),
     {:ok, cache_buffer} <- CacheBuffer.new(request.cache_key, resolved_output, request.opts),
     {:ok, stream, content_type} <-
       Encoder.stream_output(final_state.image, resolved_output, request.opts),
     {:ok, first_chunk, suspended} <- first_chunk(stream) do
  cache_buffer = CacheBuffer.append(cache_buffer, first_chunk, request.opts)
  state = %{state | suspended: suspended, resolved_output: resolved_output, cache_buffer: cache_buffer}

  case receive_linked_exit(:ok, state.parent) do
    :ok ->
      prepared = %Prepared{
        first_chunk: first_chunk,
        content_type: content_type,
        headers: resolved_output.response_headers,
        resolved_output: resolved_output
      }

      {:ok, prepared, state}

    {:error, reason} ->
      {:error, reason, shutdown_halt_stream(state, :stream_error)}

    {:shutdown, reason} ->
      {:shutdown, reason, shutdown_halt_stream(state, :owner_down)}
  end
else
  {:shutdown, reason} ->
    {:shutdown, reason, shutdown_halt_stream(state, :owner_down)}

  {:error, reason} ->
    {:error, reason, shutdown_halt_stream(state, :stream_error)}

  :empty ->
    {:error, {:encode, RuntimeError.exception("image encoder produced an empty stream"), []}, state}
end
```

Keep the existing source/decode/output/encode behavior. The new pre-response failure is invalid cacheable headers from `CacheBuffer.new/3`; it should surface as `{:invalid_cache_headers, reason}` through the existing processing error path.

- [ ] **Step 4: Append later chunks and commit on done**

Update `reduce_result/2` so cache state changes stay inside `SourceSession`.

Slice 5 implementation found that the checked-in Vix `write_to_stream/3` reports normal EOF as `{:halted, acc}` because its `Stream.resource/3` next callback returns `{:halt, pipe}` on `:eof`. Treat both `{:done, _acc}` and `{:halted, _acc}` as terminal completion after checking pending owner and linked-exit messages. Explicit cancellation still runs through `halt_stream/1`, not through the `next/1` completion path, so it doesn't commit cache.

```elixir
defp reduce_result({:suspended, chunk, continuation}, state) when is_binary(chunk) do
  cache_buffer = CacheBuffer.append(state.cache_buffer, chunk, state.request.opts)

  {{:chunk, chunk}, %{state | suspended: {chunk, continuation}, cache_buffer: cache_buffer}}
end

defp reduce_result({:done, _acc}, state), do: finish_stream(state)
defp reduce_result({:halted, _acc}, state), do: finish_stream(state)

defp finish_stream(state) do
  case receive_session_control_message(:ok, state) do
    :ok ->
      _result = CacheBuffer.commit(state.cache_buffer, state.request.opts)
      {:done, %{state | suspended: nil, cache_buffer: nil}}

    {:error, reason} ->
      {{:error, reason}, abandon_cache_buffer(state, :stream_error)}

    {:shutdown, reason} ->
      reason = {:session, {:shutdown, reason}}
      {{:error, reason}, abandon_cache_buffer(state, :owner_down)}
  end
end
```

Don't let cache write errors change `next/1` from `:done` to `{:error, reason}`. After headers commit, cache write errors fail open.

`receive_session_control_message/2` should be a renamed or extracted form of the existing non-blocking linked-exit check. It must also consume pending owner `:DOWN` messages before cache commit:

```elixir
defp receive_session_control_message(result, %{owner: owner, owner_monitor: ref, parent: parent}) do
  receive do
    {:DOWN, ^ref, :process, ^owner, reason} ->
      {:shutdown, {:owner_down, reason}}

    {:EXIT, pid, :shutdown} when is_pid(parent) and pid == parent ->
      {:shutdown, :shutdown}

    {:EXIT, pid, {:shutdown, _reason} = shutdown} when is_pid(parent) and pid == parent ->
      {:shutdown, shutdown}

    {:EXIT, _pid, {%StreamError{reason: reason}, _stacktrace}} ->
      {:error, {:source, reason}}

    {:EXIT, _pid, %StreamError{reason: reason}} ->
      {:error, {:source, reason}}

    {:EXIT, _pid, :normal} ->
      receive_session_control_message(result, %{owner: owner, owner_monitor: ref, parent: parent})

    {:EXIT, pid, reason} when pid != parent ->
      {:error, {:linked_exit, pid, reason}}
  after
    0 -> result
  end
end
```

Use this check before committing cache on stream completion so a pending owner death can't produce a cache entry.

- [ ] **Step 5: Abandon buffers on cancellation, owner death, and stream errors**

Replace `shutdown_halt_stream/1` with reason-aware cleanup:

```elixir
defp shutdown_halt_stream(state, reason \\ :cancelled) do
  state = abandon_cache_buffer(state, reason)

  case halt_stream(state) do
    {:ok, state} -> state
    {:error, reason, state} -> mark_failed(state, {:cancel, reason})
  end
end

defp abandon_cache_buffer(%{cache_buffer: cache_buffer, request: request} = state, reason) do
  _result = CacheBuffer.abandon(cache_buffer, reason, request.opts)
  %{state | cache_buffer: nil}
end
```

Use explicit reasons at call sites:

```elixir
shutdown_halt_stream(%{state | phase: :cancelled}, :cancelled)
shutdown_halt_stream(%{state | phase: :cancelled}, :owner_down)
shutdown_halt_stream(state, :stream_error)
```

In `handle_call(:next, ...)`, when `next_chunk/1` returns `{{:error, reason}, state}`, abandon before stopping:

```elixir
state = state |> abandon_cache_buffer(:stream_error) |> mark_failed(reason)
{:stop, :normal, {:error, reason}, state}
```

Don't emit abandoned telemetry for buffers that were already dropped due to `max_body_bytes`.

Update `terminate/2` to use the same idempotent cleanup path for abnormal active exits:

```elixir
def terminate(reason, state) when reason not in [:normal, :shutdown] do
  _state = shutdown_halt_stream(%{state | phase: :cancelled}, :stream_error)
  :ok
end
```

Keep the existing shutdown-specific `terminate/2` clauses. The cleanup helpers must clear `cache_buffer` after emitting abandoned telemetry so `terminate/2` doesn't run cleanup twice after an earlier call path already cleaned up.

- [ ] **Step 6: Format changed source session files**

Run:

```bash
mise exec -- mix format lib/image_plug/request/source_session/request.ex lib/image_plug/request/source_session.ex lib/image_plug/request/source_session/cache_buffer.ex
```

Expected: formatter succeeds.

- [ ] **Step 7: Run protocol tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs
```

Expected: PASS.

## Task 4: Route Configured Fail-Open Cache Misses Through Prepared Streams

Change `Runner` so configured cache misses use `SourceSession` with a cache key, while fail-closed cache misses keep the old pre-response full encode/cache path.

**Files:**
- Edit: `test/image_plug/request_runner_test.exs`
- Edit: `lib/image_plug/request/runner.ex`

- [ ] **Step 1: Update cache probes so session-process writes reach the test process**

`Cache.put/3` runs inside `SourceSession` on the prepared-stream path. Direct `send(self(), ...)` calls in cache adapters send to the session, not the ExUnit process. Update the probe modules so events that must be asserted from tests go to `:test_pid`.

Update `CacheMissWriteProbe.put/3`:

```elixir
def put(key, entry, opts) do
  emit(opts, {:cache_put, key, entry})
  send(Keyword.get(opts, :test_pid, self()), {:cache_put, key, entry, opts})
  :ok
end
```

Update `CacheReadErrorWriteProbe.put/3`:

```elixir
def put(key, entry, opts) do
  emit(opts, {:cache_put, key, entry})
  send(Keyword.get(opts, :test_pid, self()), {:cache_put, key, entry, opts})
  :ok
end
```

Keep the existing lookup events.

Update `CacheHitWriteProbe.put/3` the same way because fail-open invalid cached delivery now retries through a supervised `SourceSession`:

```elixir
def put(key, entry, opts) do
  send(Keyword.get(opts, :test_pid, self()), {:cache_put, key, entry, opts})
  :ok
end
```

- [ ] **Step 2: Update configured miss tests to expect prepared streams**

Replace `test "configured cache miss stays on pre-response cache path before cache teeing"` with:

```elixir
test "configured cache miss writes cache after successful prepared stream delivery" do
  supervisor = start_source_session_supervisor()
  ref = make_ref()

  assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response}} =
           Runner.run(
             conn(:get, "/_/plain/images/beach.jpg"),
             plan(),
             resolved_source(cache: :normal),
             cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
             source_session_supervisor: supervisor,
             sources: %{path: {SourceImage, []}}
           )

  assert_received {:cache_lookup, key}
  refute_received {:cache_put, _key, _entry, _opts}
  assert_supervisor_active(supervisor)

  conn =
    ImagePlug.Response.Sender.send_result(
      conn(:get, "/image"),
      {:ok, {:prepared_stream, prepared, response}},
      []
    )

  assert conn.status == 200
  assert is_binary(conn.resp_body)
  assert byte_size(conn.resp_body) > 0

  assert_received {:runner_event, ^ref, {:cache_put, ^key, %Entry{content_type: "image/jpeg", body: body}}}
  assert is_binary(body)
  assert byte_size(body) > 0
  assert_supervisor_empty(supervisor)
end
```

Replace `test "cache read fail-open miss stays on pre-response cache path before cache teeing"` with:

```elixir
test "cache read fail-open miss returns a prepared stream and writes cache after successful drain" do
  supervisor = start_source_session_supervisor()
  ref = make_ref()

  assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, %Response{}}} =
           Runner.run(
             conn(:get, "/_/plain/images/beach.jpg"),
             plan(),
             resolved_source(cache: :normal),
             cache: {CacheReadErrorWriteProbe, test_pid: self(), test_ref: ref},
             source_session_supervisor: supervisor,
             sources: %{path: {SourceImage, []}}
           )

  assert_received {:runner_event, ^ref, {:cache_lookup, key}}
  refute_received {:runner_event, ^ref, {:cache_put, _key, %Entry{}}}
  assert_supervisor_active(supervisor)

  assert :ok = drain_prepared_stream(prepared)

  assert_received {:runner_event, ^ref, {:cache_put, ^key, %Entry{content_type: "image/jpeg"}}}
  assert_supervisor_empty(supervisor)
end
```

Add this helper near the existing prepared stream helpers:

```elixir
defp drain_prepared_stream(%PreparedStream{} = prepared) do
  case prepared.next.() do
    {:chunk, chunk} when is_binary(chunk) -> drain_prepared_stream(prepared)
    :done -> :ok
    {:error, reason} -> flunk("expected prepared stream to complete, got #{inspect(reason)}")
  end
end
```

- [ ] **Step 3: Add fail-closed miss coverage**

Append this test near the cache miss tests:

```elixir
test "configured cache miss with fail_on_cache_error true keeps the pre-response cache path" do
  supervisor = start_source_session_supervisor()
  ref = make_ref()

  assert {:ok, {:cache_entry, %Entry{content_type: "image/jpeg"}, %Response{}}} =
           Runner.run(
             conn(:get, "/_/plain/images/beach.jpg"),
             plan(),
             resolved_source(cache: :normal),
             cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref, fail_on_cache_error: true},
             source_session_supervisor: supervisor,
             sources: %{path: {SourceImage, []}}
           )

  assert_received {:cache_lookup, _key}
  assert_received {:cache_put, _key, %Entry{}, _opts}
  assert_supervisor_empty(supervisor)
end
```

- [ ] **Step 4: Add sender-delivery dependency coverage**

Add one runner test that uses `Response.Sender`. The closing chunk adapter from `ImagePlug.Response.SenderTest` isn't available here, so define a local adapter in `test/image_plug/request_runner_test.exs`:

```elixir
defmodule ClosingAfterFirstChunkAdapter do
  @behaviour Plug.Conn.Adapter

  @impl Plug.Conn.Adapter
  def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

  @impl Plug.Conn.Adapter
  def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

  @impl Plug.Conn.Adapter
  def send_chunked(payload, _status, _headers), do: {:ok, "", %{payload | chunks: 0}}

  @impl Plug.Conn.Adapter
  def chunk(%{chunks: 0} = payload, body),
    do: {:ok, IO.iodata_to_binary(body), %{payload | chunks: 1}}

  def chunk(_payload, _body), do: {:error, :closed}

  @impl Plug.Conn.Adapter
  def read_req_body(payload, _opts), do: {:ok, "", payload}

  @impl Plug.Conn.Adapter
  def inform(payload, _status, _headers), do: {:ok, payload}

  @impl Plug.Conn.Adapter
  def push(payload, _path, _headers), do: {:ok, payload}

  @impl Plug.Conn.Adapter
  def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}

  @impl Plug.Conn.Adapter
  def get_http_protocol(_payload), do: :"HTTP/1.1"

  @impl Plug.Conn.Adapter
  def upgrade(payload, _protocol, _opts), do: {:ok, payload}
end
```

Also define these local adapters:

```elixir
defmodule FailingChunkedAdapter do
  @behaviour Plug.Conn.Adapter

  @impl Plug.Conn.Adapter
  def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

  @impl Plug.Conn.Adapter
  def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

  @impl Plug.Conn.Adapter
  def send_chunked(_payload, _status, _headers), do: raise("chunked open failed")

  @impl Plug.Conn.Adapter
  def chunk(payload, body), do: {:ok, IO.iodata_to_binary(body), payload}

  @impl Plug.Conn.Adapter
  def read_req_body(payload, _opts), do: {:ok, "", payload}

  @impl Plug.Conn.Adapter
  def inform(payload, _status, _headers), do: {:ok, payload}

  @impl Plug.Conn.Adapter
  def push(payload, _path, _headers), do: {:ok, payload}

  @impl Plug.Conn.Adapter
  def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}

  @impl Plug.Conn.Adapter
  def get_http_protocol(_payload), do: :"HTTP/1.1"

  @impl Plug.Conn.Adapter
  def upgrade(payload, _protocol, _opts), do: {:ok, payload}
end

defmodule FirstChunkClosedAdapter do
  @behaviour Plug.Conn.Adapter

  @impl Plug.Conn.Adapter
  def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

  @impl Plug.Conn.Adapter
  def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

  @impl Plug.Conn.Adapter
  def send_chunked(payload, _status, _headers), do: {:ok, "", payload}

  @impl Plug.Conn.Adapter
  def chunk(_payload, _body), do: {:error, :closed}

  @impl Plug.Conn.Adapter
  def read_req_body(payload, _opts), do: {:ok, "", payload}

  @impl Plug.Conn.Adapter
  def inform(payload, _status, _headers), do: {:ok, payload}

  @impl Plug.Conn.Adapter
  def push(payload, _path, _headers), do: {:ok, payload}

  @impl Plug.Conn.Adapter
  def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}

  @impl Plug.Conn.Adapter
  def get_http_protocol(_payload), do: :"HTTP/1.1"

  @impl Plug.Conn.Adapter
  def upgrade(payload, _protocol, _opts), do: {:ok, payload}
end
```

Add these tests:

```elixir
test "streamed cache miss doesn't write cache when the client closes before done" do
  supervisor = start_source_session_supervisor()
  ref = make_ref()

  assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response}} =
           Runner.run(
             conn(:get, "/_/plain/images/beach.jpg"),
             plan(),
             resolved_source(cache: :normal),
             cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
             source_session_supervisor: supervisor,
             sources: %{path: {SourceImage, []}}
           )

  conn =
    :get
    |> conn("/image")
    |> Map.put(:adapter, {ClosingAfterFirstChunkAdapter, %{chunks: nil}})
    |> ImagePlug.Response.Sender.send_result({:ok, {:prepared_stream, prepared, response}}, [])

  assert conn.private.image_plug_send_result == :processing_error
  assert_received {:cache_lookup, _key}
  refute_received {:cache_put, _key, _entry, _opts}
  assert_supervisor_empty(supervisor)
end

test "streamed cache miss doesn't write cache when send_chunked fails" do
  supervisor = start_source_session_supervisor()
  ref = make_ref()

  assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response}} =
           Runner.run(
             conn(:get, "/_/plain/images/beach.jpg"),
             plan(),
             resolved_source(cache: :normal),
             cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
             source_session_supervisor: supervisor,
             sources: %{path: {SourceImage, []}}
           )

  conn =
    :get
    |> conn("/image")
    |> Map.put(:adapter, {FailingChunkedAdapter, %{}})
    |> ImagePlug.Response.Sender.send_result({:ok, {:prepared_stream, prepared, response}}, [])

  assert conn.private.image_plug_send_result == :processing_error
  assert_received {:cache_lookup, _key}
  refute_received {:cache_put, _key, _entry, _opts}
  assert_supervisor_empty(supervisor)
end

test "streamed cache miss doesn't write cache when the first chunk fails" do
  supervisor = start_source_session_supervisor()
  ref = make_ref()

  assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response}} =
           Runner.run(
             conn(:get, "/_/plain/images/beach.jpg"),
             plan(),
             resolved_source(cache: :normal),
             cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
             source_session_supervisor: supervisor,
             sources: %{path: {SourceImage, []}}
           )

  conn =
    :get
    |> conn("/image")
    |> Map.put(:adapter, {FirstChunkClosedAdapter, %{}})
    |> ImagePlug.Response.Sender.send_result({:ok, {:prepared_stream, prepared, response}}, [])

  assert conn.private.image_plug_send_result == :processing_error
  assert_received {:cache_lookup, _key}
  refute_received {:cache_put, _key, _entry, _opts}
  assert_supervisor_empty(supervisor)
end
```

- [ ] **Step 5: Add cache write fail-open delivery coverage**

Add a runner-test cache adapter:

```elixir
defmodule CacheWriteErrorProbe do
  def get(key, opts) do
    emit(opts, {:cache_lookup, key})
    :miss
  end

  def put(_key, entry, opts) do
    emit(opts, {:cache_put_attempted, entry})
    {:error, :write_failed}
  end

  defp emit(opts, event) do
    case Keyword.fetch(opts, :test_pid) do
      {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), event})
      :error -> :ok
    end
  end
end
```

Add the test:

```elixir
test "streamed cache miss cache write errors fail open after successful delivery" do
  attach_telemetry([[:image_plug, :cache, :write, :stop]])

  supervisor = start_source_session_supervisor()
  ref = make_ref()

  assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response}} =
           Runner.run(
             conn(:get, "/_/plain/images/beach.jpg"),
             plan(),
             resolved_source(cache: :normal),
             cache: {CacheWriteErrorProbe, test_pid: self(), test_ref: ref},
             source_session_supervisor: supervisor,
             sources: %{path: {SourceImage, []}}
           )

  conn =
    ImagePlug.Response.Sender.send_result(
      conn(:get, "/image"),
      {:ok, {:prepared_stream, prepared, response}},
      []
    )

  assert conn.status == 200
  refute Map.get(conn.private, :image_plug_send_result) == :processing_error
  assert_received {:runner_event, ^ref, {:cache_put_attempted, %Entry{}}}
  assert_supervisor_empty(supervisor)

  assert_receive {:telemetry_event, [:image_plug, :cache, :write, :stop], _measurements,
                  %{result: :cache_error, cache: :write_error, error: :write_failed}}
end
```

- [ ] **Step 6: Preserve cache skip and hit behavior**

Update the existing `cache-skip explicit output returns a prepared stream delivery even when cache is configured` test to keep asserting:

```elixir
refute_received {:cache_lookup, _key}
refute_received {:cache_put, _key, _entry, _opts}
```

Leave valid cache hit tests expecting `{:cache_entry, entry, response}`.

Replace the fail-open half of `test "unsupported cached delivery content type fails open by default and fails closed when configured"` so invalid cached delivery returns a prepared stream and writes only after delivery:

```elixir
assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, ^response}} =
         Runner.run(
           conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
           plan(response: response),
           resolved_source(),
           cache: {CacheHitWriteProbe, entry: invalid_entry},
           source_session_supervisor: supervisor,
           sources: %{path: {SourceImage, []}}
         )

assert_received {:cache_lookup, key}
refute_received {:cache_put, _key, _entry, _opts}

assert :ok = drain_prepared_stream(prepared)
assert_received {:cache_put, ^key, %Entry{content_type: "image/jpeg"}, _opts}
```

Keep the fail-closed half expecting:

```elixir
assert {:error, {:cache, {:unsupported_delivery_content_type, "image/gif"}}} =
         Runner.run(
           conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
           plan(response: response),
           resolved_source(),
           cache: {CacheHit, entry: invalid_entry, fail_on_cache_error: true}
         )
```

Add one automatic output miss test so cacheable response headers still round-trip through the streamed tee path:

```elixir
test "streamed automatic cache miss writes negotiated entry with Vary" do
  supervisor = start_source_session_supervisor()
  ref = make_ref()

  assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, %ImagePlug.Plan.Response{}}} =
           Runner.run(
             conn(:get, "/_/f:auto/plain/images/beach.jpg", "")
             |> Plug.Conn.put_req_header("accept", "image/webp,image/jpeg;q=0.8"),
             plan(output: %Output{mode: :automatic}),
             resolved_source(cache: :normal),
             cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
             source_session_supervisor: supervisor,
             sources: %{path: {SourceImage, []}}
           )

  assert_received {:cache_lookup, key}
  assert :ok = drain_prepared_stream(prepared)

  assert_received {:runner_event, ^ref,
                   {:cache_put, ^key,
                    %Entry{
                      body: body,
                      content_type: content_type,
                      headers: [{"vary", "Accept"}]
                    }}}

  assert is_binary(body)
  assert content_type in ["image/webp", "image/jpeg"]
  assert_supervisor_empty(supervisor)
end
```

- [ ] **Step 7: Run runner tests and verify they fail**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request_runner_test.exs
```

Expected: FAIL because `Runner` still sends configured cache misses through `process_cache_miss/5`.

- [ ] **Step 8: Pass cache key into prepared stream sessions**

Edit `lib/image_plug/request/runner.ex`.

Change configured miss routing:

```elixir
{:miss, %Key{} = key} ->
  process_cacheable_miss(conn, plan, resolved_source, key, opts)

{:miss, %Key{} = key, {:cache_read, _error}} ->
  process_cacheable_miss(conn, plan, resolved_source, key, opts)
```

Add:

```elixir
defp process_cacheable_miss(conn, plan, resolved_source, %Key{} = key, opts) do
  if Cache.fail_on_cache_error?(opts) do
    process_cache_miss(conn, plan, resolved_source, key, opts)
  else
    process_prepared_stream(conn, plan, resolved_source, key, opts)
  end
end
```

Change `:disabled` and `cache: :skip` paths to pass `nil` explicitly:

```elixir
defp run_with_cache_config(conn, plan, %Source.Resolved{cache: :skip} = resolved_source, opts),
  do: process_prepared_stream(conn, plan, resolved_source, nil, opts)
```

```elixir
:disabled ->
  process_prepared_stream(conn, plan, resolved_source, nil, opts)
```

Change `handle_cache_delivery_error/6` so fail-open invalid cached delivery uses the cache tee path:

```elixir
defp handle_cache_delivery_error(conn, plan, resolved_source, key, opts, error) do
  if Cache.fail_on_cache_error?(opts) do
    {:error, {:cache, error}}
  else
    process_prepared_stream(conn, plan, resolved_source, key, opts)
  end
end
```

Change `process_prepared_stream/4` to `process_prepared_stream/5`:

```elixir
defp process_prepared_stream(conn, plan, resolved_source, cache_key, opts) do
  policy = Policy.from_output_plan(conn, plan.output, opts)

  request = %SessionRequest{
    plan: plan,
    resolved_source: resolved_source,
    output_policy: policy,
    opts: opts,
    cache_key: cache_key
  }

  supervisor = Keyword.get(opts, :source_session_supervisor, SourceSessionSupervisor)

  case SourceSessionSupervisor.start_session(supervisor, request) do
    {:ok, session} ->
      prepare_supervised_session(session, supervisor, plan.response, policy)

    {:error, reason} ->
      {:error, {:processing, normalize_session_prepare_error(reason), policy.headers}}
  end
end
```

- [ ] **Step 9: Format runner and test files**

Run:

```bash
mise exec -- mix format lib/image_plug/request/runner.ex test/image_plug/request_runner_test.exs
```

Expected: formatter succeeds.

- [ ] **Step 10: Run runner tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request_runner_test.exs
```

Expected: PASS.

## Task 5: Add Architecture Coverage For Cache Ownership

Make the intended boundary explicit: request lifecycle code may depend on cache, response delivery must not.

**Files:**
- Edit: `test/image_plug/architecture_boundary_test.exs`

- [ ] **Step 1: Add a response boundary guard against cache tee leakage**

Append or extend the existing prepared stream boundary test:

```elixir
test "response delivery stays unaware of source sessions and cache teeing" do
  forbidden_terms = [
    "ImagePlug.Request.SourceSession",
    "ImagePlug.Request.SourceSessionSupervisor",
    "Cache.put",
    "Cache.Key",
    "SourceSession.CacheBuffer",
    "cache_buffer"
  ]

  violations =
    for file <- ["lib/image_plug/response/prepared_stream.ex", "lib/image_plug/response/sender.ex"],
        File.exists?(file),
        {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        term <- forbidden_terms,
        String.contains?(line, term) do
      "#{file}:#{number} must not depend on #{term}; SourceSession owns cache teeing"
    end

  assert violations == []
end
```

If an existing test already checks source session terms in response files, replace it with this broader cache ownership test instead of duplicating source-text scans.

- [ ] **Step 2: Run architecture tests**

Run:

```bash
mise exec -- mix test test/image_plug/architecture_boundary_test.exs
```

Expected: PASS.

## Task 6: Focused Verification

Run the focused tests that cover the changed behavior and adjacent contracts.

**Files:**
- No edits.

- [ ] **Step 1: Run SourceSession, Runner, Sender, and architecture tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs test/image_plug/request_runner_test.exs test/image_plug/response_sender_test.exs test/image_plug/architecture_boundary_test.exs
```

Expected: PASS.

- [ ] **Step 2: Run SourceSession supervision and Vix continuation regression tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_supervisor_test.exs test/image_plug/request/vix_stream_continuation_test.exs
```

Expected: PASS.

- [ ] **Step 3: Compile with warnings as errors**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix compile --warnings-as-errors
```

Expected: PASS.

## Task 7: Parallel Review Checkpoint

Run the required parallel subagent review cycle before committing Slice 5.

**Files:**
- Review changed files from Tasks 1-5.

- [ ] **Step 1: Dispatch four reviewers in parallel**

Use `superpowers:subagent-driven-development` review practice and ask for disjoint reviews:

1. **Cache correctness and cache contract**
   - Check routing table behavior.
   - Check cache commit conditions.
   - Check `max_body_bytes` drop behavior.
   - Check fail-open vs fail-closed cache error behavior.
   - Check cache entry headers and body construction.

2. **SourceSession lifecycle and cleanup**
   - Check `GenServer` state transitions.
   - Check cancellation and owner-death cache abandonment.
   - Check no double cleanup callback or double cache telemetry on stream errors.
   - Check `next/1` commits only after the stream reaches `:done`.

3. **Response delivery interaction**
   - Check that `Response.Sender` remains cache-unaware.
   - Check that sender cancellation still drops cache buffers.
   - Check that cache writes only happen after successful delivered chunks.
   - Check post-commit cache write errors don't become response failures.

4. **Test quality and architecture boundaries**
   - Check tests prove behavior, not private helper names.
   - Check tests avoid `Process.sleep/1` and `Process.alive?/1`.
   - Check architecture tests enforce current dependency direction.
   - Check no stale Slice 4 assumptions remain.

- [ ] **Step 2: Apply accepted feedback**

For each review item:

- accept if it identifies a real contract gap, cleanup bug, missing assertion, or architecture leak,
- reject if it asks for public docs, cache tee configuration, `Response.Sender` cache knowledge, or behavior for impossible internal misuse,
- update this plan only if the feedback changes the implementation approach before code is committed.

- [ ] **Step 3: Rerun verification**

After accepted fixes, rerun:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs test/image_plug/request_runner_test.exs test/image_plug/response_sender_test.exs test/image_plug/architecture_boundary_test.exs
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_supervisor_test.exs test/image_plug/request/vix_stream_continuation_test.exs
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix compile --warnings-as-errors
```

Expected: all PASS.

## Task 8: Commit And Stop

Commit only after implementation, review, and verification are complete.

**Files:**
- Include all changed Slice 5 implementation and test files.

- [ ] **Step 1: Run Vale if this plan changed during implementation**

Run:

```bash
mise exec -- vale docs/superpowers/plans/2026-05-23-source-session-cache-tee.md
```

Expected: PASS.

- [ ] **Step 2: Check status**

Run:

```bash
mise exec -- git status --short
```

Expected: only Slice 5 files are changed.

- [ ] **Step 3: Commit**

Run:

```bash
mise exec -- git add lib/image_plug/request/source_session/cache_buffer.ex lib/image_plug/request/source_session/request.ex lib/image_plug/request/source_session.ex lib/image_plug/request/runner.ex test/image_plug/request/source_session_test.exs test/image_plug/request_runner_test.exs test/image_plug/architecture_boundary_test.exs
mise exec -- git commit -m "Add source session cache tee"
```

- [ ] **Step 4: Stop before Slice 6**

Don't add public docs in this slice. Don't remove `SourceStreamBoundary` unless a separate plan proves the fail-closed cache miss path no longer uses it.

## Stop Criteria

Stop and ask for a design decision if any of these happen:

- cache commit requires `Response.Sender` to know about cache internals,
- `SourceSession.next/1` can't distinguish normal `:done` from cancellation or stream failure,
- cache write failures after headers commit would change a successful response into a stream failure,
- fail-closed cache misses can't stay on the pre-response full encode/cache path,
- body-limit behavior needs disk spooling or another storage adapter instead of bounded memory buffering.

## Self-Review

Spec coverage:

- configured cache misses move to supervised `SourceSession`,
- `SourceSession` owns bounded buffering and cache writes,
- sender remains cache-unaware,
- cache commit happens only after `:done`,
- partial responses and cancellations don't write cache entries,
- cache body limit drops buffering and keeps streaming,
- cache write errors fail open after headers commit,
- cache hits and `cache: :skip` are preserved,
- pinned Vix fork dependency remains explicit,
- subagent review checkpoint is included.

Placeholder scan:

- No placeholder markers remain.
- Code snippets use concrete module, function, and test names.

Type consistency:

- `SourceSession.Request.cache_key` is `ImagePlug.Cache.Key.t() | nil`.
- `SourceSession.CacheBuffer` stores `ImagePlug.Cache.Entry` data and writes through `ImagePlug.Cache.put/3`.
- `Runner` passes the cache key only for configured fail-open cache miss paths.
