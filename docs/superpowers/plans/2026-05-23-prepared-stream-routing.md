# Prepared Stream Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans for this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route no-cache and cache-skip responses through supervised `SourceSession` prepared streams without changing cache-miss behavior.

**Architecture:** This is Slice 4 only. `ImagePlug.Request.Runner` starts a supervised `SourceSession`, prepares the first encoded chunk before headers commit, and hands `ImagePlug.Response.Sender` a response-owned `PreparedStream` callback struct. The sender only sees bytes, headers, scalar output metadata, and callbacks. It never receives source-backed image or transform state for prepared-stream responses.

**Tech Stack:** Elixir, OTP `DynamicSupervisor`, `GenServer` call wrappers, Plug response streaming, ExUnit, Boundary, pinned Vix fork `3a30758d44526d3c914b2076bd0be201c972f2b7`, `mise exec -- mix`.

---

## Preconditions

Slice 3 landed in `37e4a00 Add source session supervision`.

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

Don't start Slice 5 from this plan. Slice 4 ends after prepared-stream routing implementation, focused verification, the required parallel review cycle, accepted fixes, Vale, commit, and a stop before cache teeing.

## Files

- Create: `lib/image_plug/response/prepared_stream.ex`
- Edit: `lib/image_plug/response.ex`
- Edit: `lib/image_plug/response/sender.ex`
- Edit: `lib/image_plug/request/runner.ex`
- Edit: `test/image_plug/response_sender_test.exs`
- Edit: `test/image_plug/request_runner_test.exs`
- Edit: `test/image_plug/architecture_boundary_test.exs`
- Read as needed: `lib/image_plug/request/source_session.ex`
- Read as needed: `lib/image_plug/request/source_session/prepared.ex`
- Read as needed: `lib/image_plug/request/source_session/request.ex`
- Read as needed: `lib/image_plug/request/source_session_supervisor.ex`
- Read as needed: `docs/superpowers/designs/2026-05-21-source-session-lifecycle-boundary.md`
- Read as needed: `docs/superpowers/plans/2026-05-23-source-session-supervision.md`

## Non-Goals

- Don't add cache teeing.
- Don't stream configured cache misses.
- Don't remove `ImagePlug.Request.SourceStreamBoundary`.
- Don't remove existing `{:image, state, resolved_output, response}` delivery yet.
- Don't change cache hit delivery.
- Don't expose `ImagePlug.Request.SourceSession`.
- Don't add public docs.
- Don't add `:gen_statem`.
- Don't move direct `SourceSession.start/2` into production routing.

## Contracts

Prepared streams are only for no-cache and `cache: :skip` responses in this slice.

The routing table must be:

| Case | Route |
| --- | --- |
| cache hit | existing `{:cache_entry, entry, response}` delivery |
| no configured cache | supervised `SourceSession` and `Response.PreparedStream` |
| resolved source has `cache: :skip` | supervised `SourceSession` and `Response.PreparedStream` |
| configured cache miss | existing pre-response full encode/cache path |
| configured cache read error with fail-open miss | existing pre-response full encode/cache path |
| configured cache read error with fail-closed error | existing cache error path |

`SourceSession.prepare/1` must finish before `Response.Sender` commits headers. If prepare fails, `Runner` returns the existing `{:error, {:processing, reason, response_headers}}` shape and stops the session. If final delivery header validation fails, `Runner` stops the session and returns a pre-response processing error.

`PreparedStream.first_chunk` must be a non-empty binary. The struct type can only document that. `Runner` must reject empty chunks before constructing it.

`Response.Sender` must call `prepared_stream.cancel.()` unless it observes normal `:done` from `prepared_stream.next.()`.

After the sender calls `send_chunked/2`, failures are stream failures. Don't try to replace them with a new HTTP error body.

## Task 1: Add PreparedStream Struct And Boundary Export

Add the response-owned handoff type before changing runner or sender behavior.

**Files:**
- Create: `lib/image_plug/response/prepared_stream.ex`
- Edit: `lib/image_plug/response.ex`
- Edit: `test/image_plug/architecture_boundary_test.exs`

- [ ] **Step 1: Update architecture test expectations first**

Edit the response boundary test in `test/image_plug/architecture_boundary_test.exs` so `PreparedStream` becomes an exported response module:

```elixir
test "response boundary owns plug response delivery" do
  response = boundary_declaration(ImagePlug.Response)

  assert_boundary_deps(response, [
    ImagePlug.Cache,
    ImagePlug.Output,
    ImagePlug.Plan,
    ImagePlug.Telemetry,
    ImagePlug.Transform
  ])

  refute_boundary_deps(response, [ImagePlug.Request, ImagePlug.Source])

  assert_boundary_exports(response, [
    ImagePlug.Response.PreparedStream,
    ImagePlug.Response.Sender
  ])
end
```

Replace the Slice 3 source-session guard test with a Slice 4 boundary-direction test:

```elixir
test "prepared stream keeps request lifecycle modules out of response delivery" do
  forbidden_terms = [
    "ImagePlug.Request.SourceSession",
    "ImagePlug.Request.SourceSessionSupervisor"
  ]

  violations =
    for file <- ["lib/image_plug/response/prepared_stream.ex", "lib/image_plug/response/sender.ex"],
        File.exists?(file),
        {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        term <- forbidden_terms,
        String.contains?(line, term) do
      "#{file}:#{number} must not depend on #{term}; use PreparedStream callbacks"
    end

  assert violations == []
end
```

- [ ] **Step 2: Run the architecture test and verify it fails**

Run:

```bash
mise exec -- mix test test/image_plug/architecture_boundary_test.exs
```

Expected: FAIL because `ImagePlug.Response.PreparedStream` doesn't exist or isn't exported yet.

- [ ] **Step 3: Add the PreparedStream module**

Create `lib/image_plug/response/prepared_stream.ex`:

```elixir
defmodule ImagePlug.Response.PreparedStream do
  @moduledoc false

  alias ImagePlug.Output.Resolved

  @enforce_keys [:first_chunk, :content_type, :headers, :next, :cancel, :resolved_output]
  defstruct @enforce_keys

  @type next_result() :: {:chunk, binary()} | :done | {:error, term()}
  @type cancel_result() :: :ok | {:error, term()}

  @type t() :: %__MODULE__{
          first_chunk: binary(),
          content_type: String.t(),
          headers: [{String.t(), String.t()}],
          next: (-> next_result()),
          cancel: (-> cancel_result()),
          resolved_output: Resolved.t()
        }
end
```

- [ ] **Step 4: Export PreparedStream from the response boundary**

Edit `lib/image_plug/response.ex`:

```elixir
defmodule ImagePlug.Response do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePlug.Cache,
      ImagePlug.Output,
      ImagePlug.Plan,
      ImagePlug.Telemetry,
      ImagePlug.Transform
    ],
    exports: [
      PreparedStream,
      Sender
    ]
end
```

- [ ] **Step 5: Run the focused architecture test**

Run:

```bash
mise exec -- mix test test/image_plug/architecture_boundary_test.exs
```

Expected: PASS.

## Task 2: Add PreparedStream Sender Behavior

Teach `ImagePlug.Response.Sender` to send a prepared stream by sending the first chunk and then pulling one chunk per callback call.

**Files:**
- Edit: `test/image_plug/response_sender_test.exs`
- Edit: `lib/image_plug/response/sender.ex`

- [ ] **Step 1: Add sender tests for successful prepared streams and cleanup**

Append these tests to `test/image_plug/response_sender_test.exs`:

```elixir
alias ImagePlug.Output.Resolved
alias ImagePlug.Response.PreparedStream

test "prepared streams send first chunk and pull later chunks" do
  parent = self()
  response = %Response{disposition: :inline, filename: "prepared"}
  next_ref = make_ref()
  replies = start_supervised!({Agent, fn -> [{:chunk, "second"}, :done] end})

  next = fn ->
    send(parent, {next_ref, :next})

    Agent.get_and_update(replies, fn
      [reply | rest] -> {reply, rest}
    end
  end

  prepared =
    prepared_stream(
      first_chunk: "first",
      headers: [{"content-disposition", ~s(inline; filename="prepared.jpg")}],
      next: next
    )

  conn = Sender.send_result(conn(:get, "/image"), {:ok, {:prepared_stream, prepared, response}}, [])

  assert conn.status == 200
  assert conn.resp_body == "firstsecond"
  assert_received {^next_ref, :next}
  assert_received {^next_ref, :next}

  assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
  assert String.starts_with?(content_type, "image/jpeg")

  assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
           [~s(inline; filename="prepared.jpg")]
end

test "prepared streams are not cancelled after normal completion" do
  parent = self()
  cancel_ref = make_ref()
  response = %Response{}

  prepared =
    prepared_stream(
      next: fn -> :done end,
      cancel: fn ->
        send(parent, cancel_ref)
        :ok
      end
    )

  conn = Sender.send_result(conn(:get, "/image"), {:ok, {:prepared_stream, prepared, response}}, [])

  assert conn.status == 200
  refute_received ^cancel_ref
end

test "prepared streams cancel when next returns an error" do
  parent = self()
  cancel_ref = make_ref()
  response = %Response{}

  prepared =
    prepared_stream(
      next: fn -> {:error, {:encode, :failed_after_first_chunk}} end,
      cancel: fn ->
        send(parent, cancel_ref)
        :ok
      end
    )

  conn = Sender.send_result(conn(:get, "/image"), {:ok, {:prepared_stream, prepared, response}}, [])

  assert conn.status == 200
  assert conn.private.image_plug_send_result == :processing_error
  assert_receive ^cancel_ref
end

defp prepared_stream(overrides \\ []) do
  struct!(
    PreparedStream,
    Keyword.merge(
      [
        first_chunk: "first",
        content_type: "image/jpeg",
        headers: [],
        next: fn -> :done end,
        cancel: fn -> :ok end,
        resolved_output: %Resolved{format: :jpeg, quality: :default, response_headers: []}
      ],
      overrides
    )
  )
end
```

- [ ] **Step 2: Run sender tests and verify they fail**

Run:

```bash
mise exec -- mix test test/image_plug/response_sender_test.exs
```

Expected: FAIL because `Sender.send_result/3` has no prepared stream clause.

- [ ] **Step 3: Add the prepared stream delivery type and `send_result/3` clause**

Edit `lib/image_plug/response/sender.ex` aliases and type:

```elixir
alias ImagePlug.Response.PreparedStream
```

```elixir
@type delivery() ::
        {:cache_entry, Entry.t(), Response.t()}
        | {:image, State.t(), Resolved.t(), Response.t()}
        | {:prepared_stream, PreparedStream.t(), Response.t()}
```

Add the `send_result/3` clause before error clauses:

```elixir
def send_result(
      conn,
      {:ok, {:prepared_stream, %PreparedStream{} = prepared_stream, %Response{} = response}},
      opts
    ) do
  send_prepared_stream(conn, prepared_stream, response, opts)
end
```

- [ ] **Step 4: Add prepared stream sending**

Add these private functions near the existing image streaming functions:

```elixir
defp send_prepared_stream(
       %Plug.Conn{} = conn,
       %PreparedStream{} = prepared_stream,
       %Response{} = _response,
       opts
     ) do
  telemetry_opts = Telemetry.telemetry_opts(opts)

  Telemetry.span(telemetry_opts, [:encode], output_metadata(prepared_stream.resolved_output), fn ->
    {conn, outcome} = do_send_prepared_stream(conn, prepared_stream)

    {conn, prepared_encode_stop_metadata(outcome, conn, prepared_stream.resolved_output)}
  end)
end

defp do_send_prepared_stream(%Plug.Conn{} = conn, %PreparedStream{} = prepared_stream) do
  case stream_prepared_chunks(conn, prepared_stream) do
    {:ok, conn} ->
      {conn, :ok}

    {:error, conn, reason} ->
      _cancel_result = prepared_stream.cancel.()
      {mark_prepared_stream_error(conn, reason), {:error, reason}}
  end
end

defp send_prepared_chunked(conn, %PreparedStream{} = prepared_stream) do
  conn
  |> put_resp_headers(prepared_stream.headers)
  |> put_resp_content_type(prepared_stream.content_type, nil)
  |> Map.put(:status, 200)
  |> send_chunked(200)
end

defp stream_prepared_chunks(conn, %PreparedStream{} = prepared_stream) do
  conn = send_prepared_chunked(conn, prepared_stream)

  case chunk(conn, prepared_stream.first_chunk) do
    {:ok, conn} ->
      continue_prepared_stream(conn, prepared_stream)

    {:error, reason} ->
      {:error, conn, {:client_closed, reason}}
  end
rescue
  exception ->
    {:error, mark_send_processing_error(conn), {:encode, {exception, __STACKTRACE__}}}
catch
  kind, reason ->
    {:error, mark_send_processing_error(conn), {kind, reason}}
end

defp continue_prepared_stream(conn, %PreparedStream{} = prepared_stream) do
  case prepared_stream.next.() do
    {:chunk, chunk} ->
      case chunk(conn, chunk) do
        {:ok, conn} ->
          continue_prepared_stream(conn, prepared_stream)

        {:error, reason} ->
          {:error, conn, {:client_closed, reason}}
      end

    :done ->
      {:ok, conn}

    {:error, reason} ->
      {:error, conn, reason}
  end
rescue
  exception ->
    {:error, mark_send_processing_error(conn), {:encode, {exception, __STACKTRACE__}}}
catch
  kind, reason ->
    {:error, mark_send_processing_error(conn), {kind, reason}}
end

defp mark_prepared_stream_error(%Plug.Conn{} = conn, reason) do
  Logger.error("prepared_stream_error: #{inspect(reason)}")
  mark_send_processing_error(conn)
end

defp prepared_encode_stop_metadata(:ok, %Plug.Conn{} = conn, %Resolved{} = resolved_output) do
  encode_stop_metadata(:ok, conn, resolved_output)
end

defp prepared_encode_stop_metadata({:error, reason}, %Plug.Conn{status: status}, resolved_output) do
  Map.merge(
    %{
      result: :processing_error,
      stream_phase: stream_error_phase(reason),
      error: Telemetry.error(reason),
      status: status
    },
    output_metadata(resolved_output)
  )
end

defp stream_error_phase({:client_closed, _reason}), do: :client
defp stream_error_phase({phase, _reason}) when phase in [:source, :decode, :output, :encode], do: phase
defp stream_error_phase(_reason), do: :encode
```

This implementation treats `PreparedStream.headers` as the already-checked final header list. Don't call `delivery_headers/3` from the prepared-stream sender path.

The explicit `Map.put(:status, 200)` before `send_chunked/2` keeps telemetry status stable if the adapter fails while opening the chunked response.

- [ ] **Step 5: Run sender tests**

Run:

```bash
mise exec -- mix test test/image_plug/response_sender_test.exs
```

Expected: PASS.

## Task 3: Route No-Cache And Cache-Skip Through SourceSession

Change `Runner` so only the prepared-stream-eligible routes use `SourceSessionSupervisor`.

**Files:**
- Edit: `test/image_plug/request_runner_test.exs`
- Edit: `lib/image_plug/request/runner.ex`

- [ ] **Step 1: Add runner routing tests**

Add aliases to `test/image_plug/request_runner_test.exs`:

```elixir
alias ImagePlug.Response.PreparedStream
alias ImagePlug.Request.SourceSessionSupervisor
```

Add these tests near the existing cache routing tests:

```elixir
test "no-cache explicit output returns a prepared stream delivery" do
  supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

  assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, %Response{}}} =
           Runner.run(
             conn(:get, "/_/plain/images/beach.jpg"),
             plan(),
             resolved_source(cache: :normal),
             source_session_supervisor: supervisor,
             sources: %{path: SourceImage}
           )

  assert is_binary(prepared.first_chunk)
  assert byte_size(prepared.first_chunk) > 0
  assert prepared.content_type == "image/jpeg"
  assert is_function(prepared.next, 0)
  assert is_function(prepared.cancel, 0)
  assert :ok = prepared.cancel.()
  assert_supervisor_empty(supervisor)
end

test "cache-skip explicit output returns a prepared stream delivery even when cache is configured" do
  supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

  assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, %Response{}}} =
           Runner.run(
             conn(:get, "/_/plain/images/beach.jpg"),
             plan(),
             resolved_source(cache: :skip),
             cache: {CacheMissWriteProbe, test_pid: self(), test_ref: make_ref()},
             source_session_supervisor: supervisor,
             sources: %{path: SourceImage}
           )

  refute_received {:cache_lookup, _key}
  refute_received {:cache_put, _key, _entry, _opts}

  assert :ok = prepared.cancel.()
  assert_supervisor_empty(supervisor)
end

test "configured cache miss stays on pre-response cache path before cache teeing" do
  supervisor = start_supervised!({SourceSessionSupervisor, name: nil})
  ref = make_ref()

  assert {:ok, {:cache_entry, %Entry{content_type: "image/jpeg"}, %Response{}}} =
           Runner.run(
             conn(:get, "/_/plain/images/beach.jpg"),
             plan(),
             resolved_source(cache: :normal),
             cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
             source_session_supervisor: supervisor,
             sources: %{path: SourceImage}
           )

  assert_received {:cache_lookup, _key}
  assert_received {:cache_put, _key, %Entry{}, _opts}
  assert_supervisor_empty(supervisor)
end

test "no-cache decode failure returns a pre-response processing error and removes the session" do
  supervisor = start_supervised!({SourceSessionSupervisor, name: nil})

  assert {:error, {:processing, {:decode, _reason}, _headers}} =
           Runner.run(
             conn(:get, "/_/plain/images/not-image.jpg"),
             plan(),
             resolved_source(cache: :normal),
             body: "not an image",
             source_session_supervisor: supervisor,
             sources: %{path: SourceBytes}
           )

  assert_supervisor_empty(supervisor)
end
```

The `source_session_supervisor` option is internal test support for isolated supervisors. Production callers should use the default named `SourceSessionSupervisor`.

- [ ] **Step 2: Run the runner tests and verify new tests fail**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request_runner_test.exs
```

Expected: FAIL because no-cache and cache-skip still return `{:image, state, resolved_output, response}`.

- [ ] **Step 3: Add Runner aliases and delivery type**

Edit `lib/image_plug/request/runner.ex`:

```elixir
alias ImagePlug.Request.SourceSession
alias ImagePlug.Request.SourceSession.Prepared, as: SessionPrepared
alias ImagePlug.Request.SourceSession.Request, as: SessionRequest
alias ImagePlug.Request.SourceSessionSupervisor
alias ImagePlug.Response.PreparedStream
```

Update `@type delivery()`:

```elixir
@type delivery() ::
        {:cache_entry, Entry.t(), Response.t()}
        | {:image, State.t(), Resolved.t(), Response.t()}
        | {:prepared_stream, PreparedStream.t(), Response.t()}
```

- [ ] **Step 4: Route cache-skip and no-cache through supervised sessions**

Keep the cache-hit and cache-miss clauses as they are. Change only these paths:

```elixir
defp run_with_cache_config(conn, plan, %Source.Resolved{cache: :skip} = resolved_source, opts),
  do: process_prepared_stream(conn, plan, resolved_source, opts)
```

In the `:disabled` cache lookup case:

```elixir
:disabled ->
  process_prepared_stream(conn, plan, resolved_source, opts)
```

Don't change `process_cache_miss/5`.

- [ ] **Step 5: Add prepared-stream processing helpers**

Add these helpers near the existing request processing helpers:

```elixir
defp process_prepared_stream(conn, plan, resolved_source, opts) do
  policy = Policy.from_output_plan(conn, plan.output, opts)

  request = %SessionRequest{
    plan: plan,
    resolved_source: resolved_source,
    output_policy: policy,
    opts: opts
  }

  supervisor = Keyword.get(opts, :source_session_supervisor, SourceSessionSupervisor)

  case SourceSessionSupervisor.start_session(supervisor, request) do
    {:ok, session} ->
      prepare_supervised_session(session, supervisor, plan.response, policy)

    {:error, reason} ->
      {:error, {:processing, normalize_session_prepare_error(reason), policy.headers}}
  end
end

defp prepare_supervised_session(session, supervisor, %Response{} = response, %Policy{} = policy) do
  case SourceSession.prepare(session) do
    {:ok, %SessionPrepared{} = prepared} ->
      case prepared_stream(session, supervisor, prepared, response) do
        {:ok, %PreparedStream{} = prepared_stream} ->
          {:ok, {:prepared_stream, prepared_stream, response}}

        {:error, reason} ->
          _stop_result = SourceSessionSupervisor.stop_session(supervisor, session)
          {:error, {:processing, normalize_session_prepare_error(reason), policy.headers}}
      end

    {:error, reason} ->
      _stop_result = SourceSessionSupervisor.stop_session(supervisor, session)
      {:error, {:processing, normalize_session_prepare_error(reason), policy.headers}}
  end
end

defp prepared_stream(session, supervisor, %SessionPrepared{} = prepared, %Response{} = response) do
  with :ok <- check_first_chunk(prepared.first_chunk),
       {:ok, content_disposition} <- Response.content_disposition(response, prepared.content_type) do
    {:ok,
     %PreparedStream{
       first_chunk: prepared.first_chunk,
       content_type: prepared.content_type,
       headers: prepared.headers ++ [{"content-disposition", content_disposition}],
       next: fn -> SourceSession.next(session) end,
       cancel: fn -> cancel_supervised_session(supervisor, session) end,
       resolved_output: prepared.resolved_output
     }}
  else
    {:error, reason} ->
      _cancel_result = SourceSession.cancel(session)
      {:error, reason}

    error ->
      _cancel_result = SourceSession.cancel(session)
      error
  end
end

defp cancel_supervised_session(supervisor, session) do
  case SourceSession.cancel(session) do
    :ok ->
      :ok

    {:error, reason} = error ->
      _stop_result = SourceSessionSupervisor.stop_session(supervisor, session)
      error
  end
end

defp check_first_chunk(chunk) when is_binary(chunk) and byte_size(chunk) > 0, do: :ok
defp check_first_chunk(_chunk), do: {:error, {:encode, RuntimeError.exception("image encoder produced an empty stream"), []}}

defp normalize_session_prepare_error({:session, reason}), do: {:encode, RuntimeError.exception("source session failed: #{inspect(reason)}"), []}
defp normalize_session_prepare_error(reason), do: reason
```

This helper is the only place that adds content disposition to prepared-stream headers. `Response.Sender` should trust `PreparedStream.headers` and must not add content disposition a second time.

The `cancel_supervised_session/2` callback keeps the supervisor as the cleanup backstop when `SourceSession.cancel/1` returns a wrapper error such as timeout or `:noproc`.

`Response.content_disposition/2` shouldn't fail for prepared streams produced by `Encoder.stream_output/3`, because the output encoder only returns delivery content types already supported by `ImagePlug.Plan.Response`. Keep the check anyway. It's the last pre-commit guard before the response handoff.

Add a test helper if the runner tests assert temporary-child cleanup:

```elixir
defp assert_supervisor_empty(supervisor) do
  _state = :sys.get_state(supervisor)
  assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(supervisor)
end
```

- [ ] **Step 6: Run runner tests**

Before running the file, update existing no-cache runner tests that still assert the old `{:image, state, resolved_output, response}` delivery shape. For no-cache routes, assert `{:prepared_stream, %PreparedStream{} = prepared, response}` and inspect `prepared.resolved_output` where the test inspected `%Resolved{}` before this slice.

Current examples to update include:

- source-only automatic output tests near the top of `test/image_plug/request_runner_test.exs`
- no-cache request-safety tests that call `Runner.run/4` directly
- `"cache hits and misses carry plan response delivery metadata"` for the miss/no-cache half if it doesn't configure cache

If a test truly needs `%ImagePlug.Transform.State{}`, move that assertion to `SourceSession` or `Processor` coverage. Another option is a configured cache-miss route when the cache path is the behavior under test.

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request_runner_test.exs
```

Expected: PASS.

## Task 4: Prove Sender Cleanup On Delivery Failures

The sender must cancel the session for delivery errors after it has accepted a prepared stream.

**Files:**
- Edit: `test/image_plug/response_sender_test.exs`
- Edit: `lib/image_plug/response/sender.ex`

- [ ] **Step 1: Add tests for cancel-on-error behavior**

Add a private test Plug adapter that fails on the second chunk:

```elixir
defmodule ClosingChunkAdapter do
  @behaviour Plug.Conn.Adapter

  @impl Plug.Conn.Adapter
  def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

  @impl Plug.Conn.Adapter
  def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

  @impl Plug.Conn.Adapter
  def send_chunked(payload, _status, _headers) do
    {:ok, "", %{payload | chunks: 0}}
  end

  @impl Plug.Conn.Adapter
  def chunk(%{chunks: 0} = payload, body) do
    {:ok, IO.iodata_to_binary(body), %{payload | chunks: 1}}
  end

  def chunk(payload, _body), do: {:error, :closed}

  @impl Plug.Conn.Adapter
  def read_req_body(payload, _opts), do: {:ok, "", payload}

  @impl Plug.Conn.Adapter
  def inform(payload, _status, _headers), do: {:ok, payload}

  @impl Plug.Conn.Adapter
  def push(payload, _path, _headers), do: {:ok, payload}

  @impl Plug.Conn.Adapter
  def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}
end

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
  def chunk(payload, _body), do: {:error, :closed}

  @impl Plug.Conn.Adapter
  def read_req_body(payload, _opts), do: {:ok, "", payload}

  @impl Plug.Conn.Adapter
  def inform(payload, _status, _headers), do: {:ok, payload}

  @impl Plug.Conn.Adapter
  def push(payload, _path, _headers), do: {:ok, payload}

  @impl Plug.Conn.Adapter
  def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}
end
```

Add tests:

```elixir
test "prepared streams cancel when client closes during later chunk" do
  parent = self()
  cancel_ref = make_ref()

  prepared =
    prepared_stream(
      next: fn -> {:chunk, "second"} end,
      cancel: fn ->
        send(parent, cancel_ref)
        :ok
      end
    )

  conn =
    :get
    |> conn("/image")
    |> Map.put(:adapter, {ClosingChunkAdapter, %{chunks: nil}})
    |> Sender.send_result({:ok, {:prepared_stream, prepared, %Response{}}}, [])

  assert conn.private.image_plug_send_result == :processing_error
  assert conn.resp_body == "first"
  assert_receive ^cancel_ref
end

test "prepared streams cancel when send_chunked fails" do
  parent = self()
  cancel_ref = make_ref()

  prepared =
    prepared_stream(
      cancel: fn ->
        send(parent, cancel_ref)
        :ok
      end
    )

  conn =
    :get
    |> conn("/image")
    |> Map.put(:adapter, {FailingChunkedAdapter, %{}})
    |> Sender.send_result({:ok, {:prepared_stream, prepared, %Response{}}}, [])

  assert conn.private.image_plug_send_result == :processing_error
  assert_receive ^cancel_ref
end

test "prepared streams cancel when first chunk fails" do
  parent = self()
  cancel_ref = make_ref()

  prepared =
    prepared_stream(
      cancel: fn ->
        send(parent, cancel_ref)
        :ok
      end
    )

  conn =
    :get
    |> conn("/image")
    |> Map.put(:adapter, {FirstChunkClosedAdapter, %{}})
    |> Sender.send_result({:ok, {:prepared_stream, prepared, %Response{}}}, [])

  assert conn.private.image_plug_send_result == :processing_error
  assert_receive ^cancel_ref
end

test "prepared streams cancel when the next callback exits" do
  parent = self()
  cancel_ref = make_ref()

  prepared =
    prepared_stream(
      next: fn -> exit(:session_down) end,
      cancel: fn ->
        send(parent, cancel_ref)
        :ok
      end
    )

  conn = Sender.send_result(conn(:get, "/image"), {:ok, {:prepared_stream, prepared, %Response{}}}, [])

  assert conn.private.image_plug_send_result == :processing_error
  assert_receive ^cancel_ref
end
```

Add one telemetry assertion for a `next` error and one for client close. Attach a temporary handler to `[:image_plug, :encode, :stop]`, then assert:

```elixir
assert_receive {[:image_plug, :encode, :stop], _measurements,
                %{result: :processing_error, stream_phase: :encode, error: :encode, status: 200, output_format: :jpeg}}
```

For client close, assert `stream_phase: :client` and `error: :client_closed`.

- [ ] **Step 2: Run sender tests**

Run:

```bash
mise exec -- mix test test/image_plug/response_sender_test.exs
```

Expected: PASS after Task 2 cleanup covers all paths.

- [ ] **Step 3: Simplify cleanup if needed**

If the Task 2 implementation duplicated cancel calls across many clauses, refactor to a single return-shape wrapper:

```elixir
defp do_send_prepared_stream(%Plug.Conn{} = conn, %PreparedStream{} = prepared_stream) do
  case stream_prepared_chunks(conn, prepared_stream) do
    {:ok, conn} ->
      {conn, :ok}

    {:error, conn, reason} ->
      _cancel_result = prepared_stream.cancel.()
      {mark_prepared_stream_error(conn, reason), {:error, reason}}
  end
end
```

Don't rely on rebinding a `completed?` variable inside `try`. Elixir rebinding inside the block won't update the outer binding.

## Task 5: Add A Wire-Level Regression Test

Add one end-to-end request test that proves no-cache image delivery still works after the runner/sender handoff changes. The runner and sender unit tests are the proof that the route is a prepared stream.

**Files:**
- Edit: `test/image_plug_test.exs` or `test/image_plug/request_runner_test.exs`

- [ ] **Step 1: Add one wire-level no-cache delivery test**

Prefer `test/image_plug_test.exs` if it already contains plug-level request tests. Otherwise keep this in `test/image_plug/request_runner_test.exs`.

Test shape:

```elixir
test "no-cache image request still sends an image" do
  conn =
    :get
    |> conn("/_/plain/images/beach.jpg")
    |> ImagePlug.call(
      parser: ImagePlug.Parser.Imgproxy,
      sources: %{path: ImagePlug.Source.File},
      cache: nil
    )

  assert conn.status == 200
  assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
  assert String.starts_with?(content_type, "image/jpeg")
  assert byte_size(conn.resp_body) > 0
end
```

If the application supervisor already starts `SourceSessionSupervisor` for tests, use it. If plug-level tests don't run the application tree, use the existing test setup pattern for starting application-owned processes.

- [ ] **Step 2: Run the wire-level test**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug_test.exs
```

Expected: PASS.

## Task 6: Architecture And Boundary Cleanup

Remove Slice 3 architecture guards that forbid the exact Slice 4 wiring, and add guards for the new contract.

**Files:**
- Edit: `test/image_plug/architecture_boundary_test.exs`
- Edit: `lib/image_plug/response.ex`

- [ ] **Step 1: Add current contract tests**

Keep the response boundary free of request/source dependencies. Add a test that response modules don't reference request lifecycle modules, and that private `SourceSession` implementation modules stay out of `ImagePlug.Request` exports:

```elixir
test "prepared stream wiring keeps lifecycle ownership in request and byte delivery in response" do
  response_sources =
    "lib/image_plug/response/**/*.ex"
    |> Path.wildcard()
    |> Map.new(fn file -> {file, File.read!(file)} end)

  violations =
    for {file, source} <- response_sources,
        term <- ["SourceSession", "SourceSessionSupervisor"],
        String.contains?(source, term) do
      "#{file} must not reference #{term}; response delivery uses PreparedStream callbacks"
    end

  assert violations == []

  request = boundary_declaration(ImagePlug.Request)

  forbidden_exports = [
    ImagePlug.Request.SourceSession,
    ImagePlug.Request.SourceSession.Prepared,
    ImagePlug.Request.SourceSession.Request
  ]

  assert Enum.filter(request.exports, &(&1 in forbidden_exports)) == []
end
```

This is an architecture boundary source test, not a private helper spelling test. It enforces the request/response dependency direction that the Boundary declarations can't fully express for callback captures.

Delete the stale `"old Runtime files are gone"` test from `test/image_plug/architecture_boundary_test.exs`. That test memorializes abandoned files instead of enforcing the current architecture.

- [ ] **Step 2: Run architecture tests**

Run:

```bash
mise exec -- mix test test/image_plug/architecture_boundary_test.exs
```

Expected: PASS.

## Task 7: Focused Verification

Run focused tests before the review cycle.

- [ ] **Step 1: Run prepared-stream focused tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/response_sender_test.exs test/image_plug/request_runner_test.exs test/image_plug/architecture_boundary_test.exs
```

Expected: PASS.

- [ ] **Step 2: Run source-session regression tests**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test test/image_plug/request/source_session_test.exs test/image_plug/request/source_session_supervisor_test.exs test/image_plug/request/vix_stream_continuation_test.exs
```

Expected: PASS.

- [ ] **Step 3: Run compile check**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix compile --warnings-as-errors
```

Expected: PASS.

## Review Checkpoint

After Task 7 passes, run the required parallel subagent review cycle before committing implementation.

Dispatch four reviewers with disjoint focus areas:

1. **Response streaming and cleanup semantics**
   - Review `ImagePlug.Response.PreparedStream`, `ImagePlug.Response.Sender`, and sender tests.
   - Check first-chunk delivery, next-loop behavior, cancel-on-error behavior, client close behavior, and post-commit error handling.
   - Verify sender doesn't try to create a replacement HTTP error body after `send_chunked/2`.

2. **Runner/session lifecycle integration**
   - Review `ImagePlug.Request.Runner`, `SourceSessionSupervisor` usage, and runner tests.
   - Check that production routing starts sessions only through the supervisor.
   - Check that prepare errors and final header errors stop sessions and return pre-response processing errors.
   - Check that configured cache misses remain on the existing pre-response full encode/cache path.

3. **Test quality**
   - Review changed tests for timing brittleness, impossible internal misuse coverage, `Process.sleep/1`, `Process.alive?/1`, and source-text assertions that don't enforce architecture.
   - Check that tests prove no-cache/cache-skip routing, cache-miss non-routing, sender cancellation, and normal completion.

4. **Architecture boundaries**
   - Review Boundary declarations, architecture tests, and boundary dependencies.
   - Check that `Response` doesn't depend on `Request` or `Source`.
   - Check that `Runner` is the only production module that closes over `SourceSession` callbacks into `PreparedStream`.

Apply accepted feedback, rerun the focused verification commands, run Vale if docs changed, then commit.

## Stop Criteria

Stop after committing Slice 4.

Don't start Slice 5 cache teeing.

Don't remove `SourceStreamBoundary`. Configured cache misses use it until cache teeing replaces that path.

Don't add public contract docs until Slice 6.
