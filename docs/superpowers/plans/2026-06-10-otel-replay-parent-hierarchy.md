# OTel Replay Parent Hierarchy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the OpenTelemetry exporter so Jaeger shows a real parent/child span hierarchy instead of a flat trace where every span is flagged "missing parent span".

**Architecture:** A new GenServer (`ImagePipe.Telemetry.Trace.OtelReplay`) buffers finished `%Trace.Span{}`s per `trace_id` and replays each trace into the OTel SDK **top-down once its root span arrives**, parenting every child onto its parent's real OTel-minted span context. `OpenTelemetryExporter.export/1` becomes a fire-and-forget cast into that server. The root span still forces ImagePipe's `trace_id` via a synthetic W3C `traceparent` remote parent (the one deliberate dangling parent per trace); everything else is properly linked.

**Tech Stack:** Elixir, `:telemetry`, `opentelemetry_api` ~> 1.5 (optional dep, public API only — `:otel_tracer.start_span/4`, `:otel_tracer.set_current_span/2`, `:otel_ctx.new/0`, `:otel_propagator_text_map.extract_to/3`), `opentelemetry` SDK ~> 1.7 (test only).

---

## Background: the bug

Jaeger reports "This trace may be incomplete: 14 spans have missing parent spans" and every span warns `parent span ID=<hex> is not in the trace; skipping clock skew adjustment`.

Root cause: `OpenTelemetryExporter` exports each finished span by synthesizing a W3C `traceparent` from ImagePipe's **internal** parent span ID (`lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex`, `parent_ctx/1`). But the OTel SDK **always mints a fresh span ID** for every span it starts — `otel_span:start_opts()` has no span-id field (verified in `deps/opentelemetry_api/src/otel_span.erl`). So no exported span ever carries an internal ID, and every parent pointer in the exported trace dangles. The trace renders flat.

Why it can't be fixed span-by-span: children finish (and export) **before** their parents (`:telemetry.span` semantics), so at child-export time the parent's OTel span context does not exist yet. The fix must buffer a trace and replay it top-down when the root finishes.

Upstream facts the fix relies on (verified against `deps/opentelemetry*` source):

- `:otel_tracer.set_current_span(:otel_ctx.new(), span_ctx)` + `:otel_tracer.start_span/4` parents the new span onto the given `span_ctx` and inherits its `trace_id` (`otel_span_utils:new_span_ctx/2`).
- Starting a child reads only the parent `span_ctx` **record** — never the SDK's span ETS table — so ending a parent before starting its children is safe, and `set_status`/`add_events` on a span before its own `end_span` are safe.
- The default `parent_based` sampler reads `is_remote` + `trace_flags` off the parent `span_ctx` record; the root's synthetic `-01` remote parent keeps the whole tree sampled.
- Supplied `start_time`/`end_span` timestamps are absolute recorded values; the SDK never stamps "now" when one is given, so replaying seconds after the spans finished exports identical timestamps.

## Design decisions (settled)

1. **Buffer + replay lives in a GenServer**, not in the exporter callback. Spans of one trace finish in **multiple processes** (`cache.write` fires from the SourceSession process, `source.fetch_decode` from a producer process — see `test/image_pipe/telemetry/trace/cross_process_test.exs`), so buffering must be shared state. A single GenServer serializes all buffer mutations, eliminating flush races. OTel span start/end calls are in-memory handoffs to the SDK's processor (the SDK batches the real I/O), so serialized replay is cheap relative to ms-scale image requests.
2. **`export/1` casts** (fire-and-forget): keeps the hot path non-blocking, exactly the "hand off to a batch processor" pattern the `Exporter` behaviour doc prescribes. Casts guarantee FIFO only per sender, and that is sufficient: replay is order-independent (buffering + the late-arrival path below), so cross-process arrival order does not matter. If the named server is down (crashed, not yet restarted), the cast silently drops — fail-open, intended for best-effort telemetry.
3. **Root detection is via a new `root: true` flag on `%Span{}` — and only the flag**, set by `Capture.on_start/4` when the process-local stack is empty. `parent_span_id == nil` is **not** treated as a root signal: with `extract_inbound: true` the real root has a non-nil (remote) parent, and conversely `ReqStep.start/1` can mint a fresh-trace, nil-parent `http.client` span when it runs in a process with no stack context — treating nil-parent as root would falsely flush such spans as one-span "traces" and break the one-dangling-root invariant. Flag-less nil-parent spans simply buffer and get flat-swept at TTL.
4. **Root keeps the synthetic traceparent** (forcing our `trace_id`). Trade-off: when ImagePipe originates the trace, Jaeger shows exactly **one** "missing parent" warning (the root's synthetic remote parent) instead of fourteen; in exchange, log↔trace correlation by `trace_id` keeps working. With `extract_inbound` behind a traced caller, the root's parent is real and there is no warning at all. Upstream consequence (`otel_span_utils:new_span_ctx/2` copies the parent ctx wholesale): every replayed span inherits `is_remote: true` from the root's remote-extracted parent — benign (`parent_span_id` linkage and sampling are correct on both `parent_based` branches), just visible as `parent_span_is_remote` in exported records.
5. **Late arrivals replay immediately**: after a trace flushes, the server keeps the internal-ID → OTel-span-ctx map (TTL-bounded) so a span finishing after the root (possible cross-process) still gets parented correctly. Known degradation: a late **child** arriving before its late **parent** falls back to a dangling synthetic parent (the parent's ctx doesn't exist yet); accepted and documented rather than re-buffered — the window is milliseconds and the spans are few.
6. **Rootless traces flush flat at TTL**: if a root never arrives (request process killed before its `:stop`), a periodic sweep replays the buffered spans — resolving parentage *within* the swept set, dangling above it — so they are degraded but visible, never silently dropped. Flushed ctx maps are also dropped at TTL. No ctx map is kept for flat-swept traces; later spans for such a trace re-buffer and are eventually flat-swept too.
7. **Memory is bounded by count, not just time**: a `max_traces` cap (default 10 000). At the cap, spans for *new* traces are shed (existing traces keep working; a root for an unseen trace still replays, just without retaining its ctx map). Worst-case resident state is therefore `max_traces` entries, not `peak-rate × TTL`. Crash/restart empties the buffer (supervisor restarts it; buffered traces are lost, already-replayed spans are safe in the SDK); there is deliberately **no shutdown flush** either. All acceptable: telemetry is best-effort.
8. **The server is a permanent child of `ImagePipe.Application`** (default `child_spec`: `restart: :permanent`, `shutdown: 5000` — deliberate, no `terminate/2`). It is inert (an empty map and a sweep timer) unless the OTel exporter is attached. Its replay code references OTel modules behind the same `@compile {:no_warn_undefined, ...}` guard as the exporter; the only caller (`OpenTelemetryExporter.export/1`) is itself guarded by `@otel_api_loaded`, so the OTel-touching code never runs when the API is absent.
9. **Replay failures never crash the server and never double-export.** A per-span rescue inside `replay_one/2` skips just the failing span (its children fall back to dangling parents); the outer rescue in `add_span/2` drops the whole trace entry, so a partially replayed tree can never sit in `{:buffering}` and be re-swept into duplicate exports. Both rescues are documented runtime-boundary degradations (the OTel SDK is third-party), matching the existing `Capture`/`FinchCapture` "a tracer must never crash" contract. No catch-all `handle_cast`/`handle_info` clauses — the only producers are trusted in-repo callers.
10. **Existing time/status/attribute/event conversion logic moves verbatim** from the exporter into the replay server (modulo dropping stale issue-number comment references). No semantic changes to those paths.

## Test-isolation contract

The OTel SDK's simple processor has **one global receiver** (`:otel_simple_processor.set_exporter(:otel_exporter_pid, self())`), and after Task 3 a **globally named** `OtelReplay` runs under the application — so any leftover buffered state in the global instance can be auto-swept (5 s timer) into whichever test currently owns the receiver. All three OTel test files (`otel_replay_test.exs`, `open_telemetry_exporter_test.exs`, `open_telemetry_integration_test.exs`) are `async: false` and must each:

- call `ImagePipe.Telemetry.Trace.OtelReplay.reset()` in `setup` (a `call`, so it also fences any pending casts from a prior test), and
- never leave the tracer attached across tests (`attach_otel_tracer/0` already detaches in `on_exit`).

With those two rules, the only spans that can reach a test's mailbox are its own; the residual 5 s-timer race is gone because the global instance's state is empty at each test start. `refute_receive` assertions are additionally fenced with a synchronous call (`:sys.get_state/1` or `reset/sweep`) so they never race an in-flight cast.

## File structure

| File | Change |
|---|---|
| `lib/image_pipe/telemetry/trace/span.ex` | Add `root: false` field + typespec |
| `lib/image_pipe/telemetry/trace/capture.ex` | Set `root:` in `on_start/4` |
| `lib/image_pipe/telemetry/trace/otel_replay.ex` | **New** — buffering + top-down replay GenServer |
| `lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex` | Slim to a cast facade; helpers move to `OtelReplay` |
| `lib/image_pipe/telemetry.ex` | Boundary `exports:` add `Trace.OtelReplay` |
| `lib/application.ex` | Boundary dep on `ImagePipe.Telemetry`; supervise `OtelReplay` |
| `test/image_pipe/telemetry/trace/capture_test.exs` | Root-flag tests |
| `test/image_pipe/telemetry/trace/otel_replay_test.exs` | **New** — unit tests for buffer/replay/sweep/cap |
| `test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs` | Adapt to buffered semantics |
| `test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs` | E2E hierarchy regression test |
| `docs/telemetry.md` | Update "OpenTelemetry export" section |
| `docs/cookbook/opentelemetry-jaeger.md` | Update expected-result wording |

---

### Task 1: `root` flag on `%Span{}`, set by `Capture`

**Files:**
- Modify: `lib/image_pipe/telemetry/trace/span.ex`
- Modify: `lib/image_pipe/telemetry/trace/capture.ex:139-158`
- Test: `test/image_pipe/telemetry/trace/capture_test.exs`

- [ ] **Step 1: Write the failing tests**

Append to `test/image_pipe/telemetry/trace/capture_test.exs` (inside the existing module; it already has `emit_nested/0` and the `TestExporter` setup):

```elixir
  test "marks the trace root with root: true and children with root: false" do
    emit_nested()

    assert_receive {:span, %Span{name: "image_pipe.transform.execute"} = child}
    assert_receive {:span, %Span{name: "image_pipe.request"} = root}

    assert root.root
    refute child.root
  end

  test "an inbound-continued root keeps root: true despite a non-nil parent" do
    ImagePipe.Telemetry.Trace.Inbound.put(%ImagePipe.Telemetry.Trace.Context{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "fedcba9876543210",
      trace_flags: 1
    })

    Telemetry.span([], [:request], %{}, fn -> {:ok, %{result: :ok}} end)

    assert_receive {:span, %Span{name: "image_pipe.request"} = root}
    assert root.root
    assert root.parent_span_id == "fedcba9876543210"
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/capture_test.exs`
Expected: 2 failures — `root.root` is `nil`/`KeyError` (field doesn't exist yet).

- [ ] **Step 3: Add the field to `Span`**

In `lib/image_pipe/telemetry/trace/span.ex`, add `root: false` to the `defstruct` keyword section (next to `trace_flags: 1`):

```elixir
    trace_flags: 1,
    root: false,
    attributes: %{},
```

and to the typespec:

```elixir
          trace_flags: non_neg_integer(),
          root: boolean(),
          attributes: map(),
```

Add one line to the `@moduledoc`: `` `root` marks the span that opened its trace in this node (set even when an inbound W3C parent gives it a remote `parent_span_id`). ``

- [ ] **Step 4: Set it in `Capture.on_start/4`**

In `lib/image_pipe/telemetry/trace/capture.ex`, replace the head of `on_start/4`:

```elixir
  defp on_start(name, measurements, meta, config) do
    {trace_id, parent_id, flags, root?} =
      case Stack.current() do
        nil ->
          {trace_id, parent_id, flags} = root_ids(config)
          {trace_id, parent_id, flags, true}

        %Span{trace_id: t, span_id: s, trace_flags: pf} ->
          {t, s, pf, false}
      end

    Stack.push(%Span{
      trace_id: trace_id,
      span_id: Id.span_id(),
      parent_span_id: parent_id,
      name: name,
      kind: :internal,
      start_time: measurements[:system_time],
      trace_flags: flags,
      attributes: safe_attrs(meta),
      pid: self(),
      node: node(),
      root: root?
    })
  end
```

Note: `Stack.adopt/1` pushes a synthetic `remote_parent` frame in hopped processes, so spans there see a non-empty stack and correctly get `root: false`. `FinchCapture` and `ReqStep` build spans directly and never set `root` — also correct: those spans are never trace roots, even when `ReqStep` mints a fresh trace with a nil parent (they buffer and flat-sweep; see design decision 3).

- [ ] **Step 5: Run tests to verify they pass**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/capture_test.exs test/image_pipe/telemetry/trace/admission_root_test.exs test/image_pipe/telemetry/trace/cross_process_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/telemetry/trace/span.ex lib/image_pipe/telemetry/trace/capture.ex test/image_pipe/telemetry/trace/capture_test.exs
git commit -m "feat(telemetry): mark trace-root spans with a root flag"
```

---

### Task 2: `OtelReplay` GenServer — buffer, top-down replay, TTL sweep, cap

**Files:**
- Create: `lib/image_pipe/telemetry/trace/otel_replay.ex`
- Test: `test/image_pipe/telemetry/trace/otel_replay_test.exs`

The conversion helpers (`kind/1`, `maybe_set_status/2`, `attributes/1`, `events/2`, `event_attrs/1`, `put_present/4`, `coerce_map/1`, `coerce/1`, `scalar_primitive?/1`, `list_elem/1`, `to_str/1`) and the traceparent construction move here from `open_telemetry_exporter.ex` (they are deleted from the exporter in Task 3 — transient duplication between these two commits is expected). Stale issue-number references in the moved comments are dropped; the behavioral content stays.

- [ ] **Step 1: Write the failing tests**

Create `test/image_pipe/telemetry/trace/otel_replay_test.exs`:

```elixir
defmodule ImagePipe.Telemetry.Trace.OtelReplayTest do
  use ExUnit.Case, async: false

  require Record

  Record.defrecordp(
    :otel_span,
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  alias ImagePipe.Telemetry.Trace.{OtelReplay, Span}

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())

    server =
      start_supervised!(
        {OtelReplay, name: :"otel_replay_#{System.unique_integer([:positive])}"}
      )

    {:ok, server: server}
  end

  @trace "0123456789abcdef0123456789abcdef"

  defp span(overrides) do
    Map.merge(
      %Span{
        trace_id: @trace,
        span_id: "89abcdef01234567",
        name: "image_pipe.request",
        start_time: System.system_time(),
        duration_native: 1,
        status: :ok,
        trace_flags: 1
      },
      Map.new(overrides)
    )
  end

  defp drain do
    receive do
      {:span, rec} -> [rec | drain()]
    after
      500 -> []
    end
  end

  test "a root span flushes immediately", %{server: server} do
    OtelReplay.add(server, span(root: true))
    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :name) == "image_pipe.request"
    assert otel_span(rec, :trace_id) == 0x0123456789ABCDEF0123456789ABCDEF
  end

  test "a nil-parent span without the root flag buffers until swept (no false root)" do
    server = start_supervised!({OtelReplay, name: :otel_replay_nilparent_test, ttl_ms: 0})

    OtelReplay.add(server, span(name: "image_pipe.http.client"))
    _ = :sys.get_state(server)
    refute_receive {:span, _}, 100

    :ok = OtelReplay.sweep(server)
    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :name) == "image_pipe.http.client"
  end

  test "children buffer until the root arrives, then parent onto OTel-minted ids", %{server: server} do
    # Finish order: deepest first (telemetry semantics).
    grandchild =
      span(
        span_id: "cccccccccccccccc",
        parent_span_id: "bbbbbbbbbbbbbbbb",
        name: "image_pipe.transform.operation"
      )

    child =
      span(
        span_id: "bbbbbbbbbbbbbbbb",
        parent_span_id: "aaaaaaaaaaaaaaaa",
        name: "image_pipe.transform.execute"
      )

    root = span(span_id: "aaaaaaaaaaaaaaaa", root: true)

    OtelReplay.add(server, grandchild)
    OtelReplay.add(server, child)
    _ = :sys.get_state(server)
    refute_receive {:span, _}, 100

    OtelReplay.add(server, root)
    recs = drain()
    assert length(recs) == 3

    by_name = Map.new(recs, &{otel_span(&1, :name), &1})
    root_rec = by_name["image_pipe.request"]
    child_rec = by_name["image_pipe.transform.execute"]
    grandchild_rec = by_name["image_pipe.transform.operation"]

    # Real OTel-minted linkage at both levels.
    assert otel_span(child_rec, :parent_span_id) == otel_span(root_rec, :span_id)
    assert otel_span(grandchild_rec, :parent_span_id) == otel_span(child_rec, :span_id)

    # All share OUR forced trace_id.
    for rec <- recs do
      assert otel_span(rec, :trace_id) == 0x0123456789ABCDEF0123456789ABCDEF
    end

    # The root's parent is the synthetic remote parent (its own internal id).
    assert otel_span(root_rec, :parent_span_id) == 0xAAAAAAAAAAAAAAAA
  end

  test "an inbound-continued root uses the real upstream parent", %{server: server} do
    OtelReplay.add(server, span(root: true, parent_span_id: "fedcba9876543210"))
    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :parent_span_id) == 0xFEDCBA9876543210
  end

  test "a late arrival after the flush parents correctly", %{server: server} do
    root = span(span_id: "aaaaaaaaaaaaaaaa", root: true)
    OtelReplay.add(server, root)
    assert_receive {:span, root_rec}, 1_000

    late =
      span(
        span_id: "dddddddddddddddd",
        parent_span_id: "aaaaaaaaaaaaaaaa",
        name: "image_pipe.cache.write"
      )

    OtelReplay.add(server, late)
    assert_receive {:span, late_rec}, 1_000
    assert otel_span(late_rec, :parent_span_id) == otel_span(root_rec, :span_id)
  end

  test "a late child arriving before its late parent dangles (documented degradation)", %{server: server} do
    OtelReplay.add(server, span(span_id: "aaaaaaaaaaaaaaaa", root: true))
    assert_receive {:span, _root_rec}, 1_000

    # Grandchild arrives post-flush while its parent (bbbb…) has not arrived yet.
    OtelReplay.add(
      server,
      span(
        span_id: "cccccccccccccccc",
        parent_span_id: "bbbbbbbbbbbbbbbb",
        name: "image_pipe.transform.operation"
      )
    )

    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :parent_span_id) == 0xBBBBBBBBBBBBBBBB
  end

  test "a buffered span whose parent chain is broken still exports on flush", %{server: server} do
    stray =
      span(
        span_id: "eeeeeeeeeeeeeeee",
        parent_span_id: "1111111111111111",
        name: "image_pipe.cache.lookup"
      )

    root = span(span_id: "aaaaaaaaaaaaaaaa", root: true)

    OtelReplay.add(server, stray)
    OtelReplay.add(server, root)

    recs = drain()
    names = Enum.map(recs, &otel_span(&1, :name))
    assert "image_pipe.cache.lookup" in names
    assert "image_pipe.request" in names
  end

  test "traces never interfere across trace_ids", %{server: server} do
    other = "ffffffffffffffffffffffffffffffff"

    OtelReplay.add(
      server,
      span(
        trace_id: other,
        span_id: "9999999999999999",
        parent_span_id: "8888888888888888",
        name: "image_pipe.parse"
      )
    )

    OtelReplay.add(server, span(root: true))
    _ = :sys.get_state(server)

    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :name) == "image_pipe.request"
    # The other trace's child stays buffered.
    refute_receive {:span, _}, 100
  end

  test "sweep flushes rootless traces flat, resolving parentage within the set" do
    server = start_supervised!({OtelReplay, name: :otel_replay_sweep_test, ttl_ms: 0})
    t0 = System.system_time()

    parent =
      span(
        span_id: "aaaaaaaaaaaaaaaa",
        parent_span_id: "0000000000000001",
        name: "image_pipe.source.fetch",
        start_time: t0
      )

    child =
      span(
        span_id: "bbbbbbbbbbbbbbbb",
        parent_span_id: "aaaaaaaaaaaaaaaa",
        name: "image_pipe.http.client",
        start_time: t0 + 10
      )

    # Child casts first (finish order); the forest replay must still nest it.
    OtelReplay.add(server, child)
    OtelReplay.add(server, parent)
    _ = :sys.get_state(server)
    refute_receive {:span, _}, 100

    :ok = OtelReplay.sweep(server)
    recs = drain()

    by_name = Map.new(recs, &{otel_span(&1, :name), &1})
    parent_rec = by_name["image_pipe.source.fetch"]
    child_rec = by_name["image_pipe.http.client"]

    # Above the swept set: dangling recorded parent id (degraded, visible).
    assert otel_span(parent_rec, :parent_span_id) == 0x0000000000000001
    # Within the swept set: real minted linkage.
    assert otel_span(child_rec, :parent_span_id) == otel_span(parent_rec, :span_id)
  end

  test "spans for new traces are shed at the max_traces cap" do
    server =
      start_supervised!({OtelReplay, name: :otel_replay_cap_test, ttl_ms: 0, max_traces: 1})

    OtelReplay.add(
      server,
      span(
        trace_id: "11111111111111111111111111111111",
        span_id: "1111111111111111",
        parent_span_id: "aaaaaaaaaaaaaaaa",
        name: "image_pipe.parse"
      )
    )

    OtelReplay.add(
      server,
      span(
        trace_id: "22222222222222222222222222222222",
        span_id: "2222222222222222",
        parent_span_id: "bbbbbbbbbbbbbbbb",
        name: "image_pipe.parse"
      )
    )

    _ = :sys.get_state(server)
    :ok = OtelReplay.sweep(server)

    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :trace_id) == 0x11111111111111111111111111111111
    # The second trace's span was shed, not buffered.
    refute_receive {:span, _}, 100
  end

  test "reset clears buffered state", %{server: server} do
    OtelReplay.add(
      server,
      span(
        span_id: "bbbbbbbbbbbbbbbb",
        parent_span_id: "aaaaaaaaaaaaaaaa",
        name: "image_pipe.parse"
      )
    )

    :ok = OtelReplay.reset(server)
    OtelReplay.add(server, span(span_id: "aaaaaaaaaaaaaaaa", root: true))

    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :name) == "image_pipe.request"
    refute_receive {:span, _}, 100
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/otel_replay_test.exs`
Expected: FAIL — `ImagePipe.Telemetry.Trace.OtelReplay` is undefined.

- [ ] **Step 3: Implement the GenServer**

Create `lib/image_pipe/telemetry/trace/otel_replay.ex`:

```elixir
defmodule ImagePipe.Telemetry.Trace.OtelReplay do
  @moduledoc false

  # Buffers finished `%ImagePipe.Telemetry.Trace.Span{}`s per trace and replays
  # each trace into a host-running OpenTelemetry SDK top-down once its root span
  # arrives, so every child is parented onto its parent's OTel-minted span
  # context.
  #
  # `OpenTelemetryExporter` is the only producer; it casts finished spans here.
  # Fail-open: if this server is down, the cast silently drops — best-effort
  # telemetry. Replay runs inside this server: serialized buffer access makes
  # cross-process span arrival race-free (replay is order-independent, so the
  # per-sender-FIFO-only guarantee of casts suffices), and the OTel calls are
  # in-memory handoffs to the SDK's processor (the SDK batches the real I/O).
  #
  # ImagePipe's trace_id is forced onto the trace via a synthetic W3C
  # traceparent remote parent on the root span only; children inherit it
  # through their parent contexts. Upstream consequence (new_span_ctx/2 copies
  # the parent ctx wholesale): every replayed span carries is_remote=true
  # inherited from the root's remote-extracted parent — benign (parent linkage
  # and sampling stay correct), just visible in exported records.
  #
  # Degradations (all best-effort by design):
  #   * a trace whose root never arrives is flushed flat by the periodic sweep
  #     after :ttl_ms — parentage resolves within the swept set, dangles above
  #     it; nothing is silently dropped;
  #   * a late span arriving after its trace flushed parents correctly while
  #     the trace's ctx map is retained (:ttl_ms window); a late child arriving
  #     BEFORE its late parent falls back to a dangling synthetic parent;
  #   * flat-swept traces keep no ctx map — later spans re-buffer and are
  #     eventually flat-swept too;
  #   * above :max_traces live traces, spans for NEW traces are shed (bounded
  #     memory beats complete telemetry);
  #   * a crash restarts the server empty: buffered traces are lost, replayed
  #     spans are already safe in the SDK. No flush runs at shutdown either.

  use GenServer

  alias ImagePipe.Telemetry.Trace.Span

  # All OTel references are runtime-only and only reachable via the guarded
  # exporter; suppress undefined-module warnings when the optional API is absent.
  @compile {:no_warn_undefined,
            [
              OpenTelemetry,
              OpenTelemetry.Span,
              :opentelemetry,
              :otel_tracer,
              :otel_ctx,
              :otel_propagator_text_map,
              :otel_propagator_trace_context
            ]}

  @default_ttl_ms 10_000
  @default_sweep_interval_ms 5_000
  @default_max_traces 10_000

  # ---- client ----------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Hand a finished span to the replay buffer. Fire-and-forget."
  @spec add(GenServer.server(), Span.t()) :: :ok
  def add(server \\ __MODULE__, %Span{} = span), do: GenServer.cast(server, {:add, span})

  @doc "Synchronously run one TTL sweep (test support)."
  @spec sweep(GenServer.server()) :: :ok
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  @doc "Drop all buffered state (test support)."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  # ---- server ----------------------------------------------------------------

  @impl true
  def init(opts) do
    state = %{
      traces: %{},
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      sweep_interval_ms: Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms),
      max_traces: Keyword.get(opts, :max_traces, @default_max_traces)
    }

    schedule_sweep(state)
    {:ok, state}
  end

  @impl true
  def handle_cast({:add, span}, state), do: {:noreply, add_span(span, state)}

  @impl true
  def handle_call(:sweep, _from, state), do: {:reply, :ok, do_sweep(state)}
  def handle_call(:reset, _from, state), do: {:reply, :ok, %{state | traces: %{}}}

  @impl true
  def handle_info(:sweep, state) do
    # Reschedule before sweeping — drift-free cadence regardless of sweep cost.
    schedule_sweep(state)
    {:noreply, do_sweep(state)}
  end

  defp schedule_sweep(state), do: Process.send_after(self(), :sweep, state.sweep_interval_ms)

  # ---- buffering state machine -------------------------------------------------
  #
  # Per-trace entry:
  #   {:buffering, [span], deadline} — children awaiting their root
  #   {:flushed, ctx_map, deadline}  — root replayed; internal span_id (hex) →
  #                                    OTel span_ctx, for late arrivals

  defp add_span(%Span{} = span, state) do
    entry = Map.get(state.traces, span.trace_id)

    cond do
      span.root ->
        {buffered, existing?} =
          case entry do
            {:buffering, spans, _deadline} -> {spans, true}
            {:flushed, _ctx_map, _deadline} -> {[], true}
            nil -> {[], false}
          end

        ctx_map = replay_tree(span, buffered)

        if existing? or map_size(state.traces) < state.max_traces do
          put_entry(state, span.trace_id, {:flushed, ctx_map, deadline(state)})
        else
          # At capacity: the root replayed, but no ctx map is retained — late
          # arrivals for this trace degrade to dangling parents.
          state
        end

      match?({:flushed, _, _}, entry) ->
        {:flushed, ctx_map, _deadline} = entry
        {_ctx, ctx_map} = replay_one(span, ctx_map)
        put_entry(state, span.trace_id, {:flushed, ctx_map, deadline(state)})

      match?({:buffering, _, _}, entry) ->
        {:buffering, list, _deadline} = entry
        put_entry(state, span.trace_id, {:buffering, [span | list], deadline(state)})

      map_size(state.traces) < state.max_traces ->
        put_entry(state, span.trace_id, {:buffering, [span], deadline(state)})

      true ->
        # Load shedding: bounded memory beats complete telemetry.
        state
    end
  rescue
    # A tracer must never crash (same contract as Capture/FinchCapture); the
    # OTel SDK is a third-party boundary. Drop the trace's entry so a partially
    # replayed tree is never re-swept into duplicate exports.
    _ -> %{state | traces: Map.delete(state.traces, span.trace_id)}
  end

  defp put_entry(state, trace_id, entry),
    do: %{state | traces: Map.put(state.traces, trace_id, entry)}

  defp deadline(state), do: System.monotonic_time(:millisecond) + state.ttl_ms

  defp do_sweep(state) do
    now = System.monotonic_time(:millisecond)

    {expired, live} =
      Enum.split_with(state.traces, fn {_trace_id, entry} -> deadline_of(entry) <= now end)

    Enum.each(expired, fn
      {_trace_id, {:buffering, spans, _deadline}} -> flat_flush(spans)
      {_trace_id, {:flushed, _ctx_map, _deadline}} -> :ok
    end)

    %{state | traces: Map.new(live)}
  end

  defp deadline_of({:buffering, _spans, deadline}), do: deadline
  defp deadline_of({:flushed, _ctx_map, deadline}), do: deadline

  # Root never arrived: degraded flat replay. Runs outside add_span's rescue,
  # so it carries its own — a sweep replay failure drops the expired spans
  # rather than killing the buffer server.
  defp flat_flush(spans) do
    _ = replay_forest(spans, %{})
    :ok
  rescue
    _ -> :ok
  end

  # ---- replay ------------------------------------------------------------------

  defp replay_tree(root, buffered) do
    {_root_ctx, ctx_map} = replay_one(root, %{})

    by_parent = Enum.group_by(buffered, & &1.parent_span_id)
    ctx_map = replay_children(root.span_id, by_parent, ctx_map)

    # Spans not reachable from the root (broken parent chain): replay them as a
    # forest so intra-set parent links still resolve — never silently lost.
    buffered
    |> Enum.reject(&Map.has_key?(ctx_map, &1.span_id))
    |> replay_forest(ctx_map)
  end

  # Replays an arbitrary set of spans, resolving parentage within the set:
  # spans whose parent is not in the set start a subtree (their parent comes
  # from ctx_map or the synthetic-traceparent fallback).
  defp replay_forest(spans, ctx_map) do
    ids = MapSet.new(spans, & &1.span_id)
    by_parent = Enum.group_by(spans, & &1.parent_span_id)

    spans
    |> Enum.reject(&MapSet.member?(ids, &1.parent_span_id))
    |> Enum.sort_by(& &1.start_time)
    |> Enum.reduce(ctx_map, fn span, acc ->
      {_ctx, acc} = replay_one(span, acc)
      replay_children(span.span_id, by_parent, acc)
    end)
  end

  defp replay_children(parent_id, by_parent, ctx_map) do
    by_parent
    |> Map.get(parent_id, [])
    |> Enum.sort_by(& &1.start_time)
    |> Enum.reduce(ctx_map, fn child, acc ->
      {_ctx, acc} = replay_one(child, acc)
      replay_children(child.span_id, by_parent, acc)
    end)
  end

  # Replays one span; returns its OTel span_ctx and the ctx_map including it.
  # A failure skips THIS span only (its children fall back to dangling parents)
  # and never aborts the surrounding tree replay — same never-crash contract as
  # add_span, localized so one bad span can't take out its siblings.
  defp replay_one(%Span{} = span, ctx_map) do
    parent_otel_ctx =
      case Map.get(ctx_map, span.parent_span_id) do
        nil -> traceparent_ctx(span)
        parent_span_ctx -> :otel_tracer.set_current_span(:otel_ctx.new(), parent_span_ctx)
      end

    span_ctx = replay_span(span, parent_otel_ctx)
    {span_ctx, Map.put(ctx_map, span.span_id, span_ctx)}
  rescue
    _ -> {nil, ctx_map}
  end

  defp replay_span(%Span{} = span, parent_otel_ctx) do
    offset = :erlang.time_offset()
    native_start = (span.start_time || 0) - offset
    native_end = native_start + (span.duration_native || 0)

    tracer = :opentelemetry.get_application_tracer(__MODULE__)

    # Erlang API: the Elixir `OpenTelemetry.Tracer.start_span` is a macro, which
    # would need `require OpenTelemetry.Tracer` — impossible to do conditionally
    # for an optional dep. Call its expansion (`:otel_tracer.start_span/4`) directly.
    span_ctx =
      :otel_tracer.start_span(parent_otel_ctx, tracer, span.name, %{
        start_time: native_start,
        kind: kind(span.kind),
        attributes: attributes(span),
        links: []
      })

    maybe_set_status(span_ctx, span)

    case events(span, native_end) do
      [] -> :ok
      evs -> OpenTelemetry.Span.add_events(span_ctx, evs)
    end

    OpenTelemetry.Span.end_span(span_ctx, native_end)
    span_ctx
  end

  # Force OUR trace_id via a synthetic remote parent: the root (and any span
  # whose parent ctx is unavailable) carries its recorded parent id, or its own
  # span_id as a dangling self-parent. -01 sampled flag is mandatory.
  defp traceparent_ctx(%Span{trace_id: trace, parent_span_id: parent, span_id: own}) do
    parent_hex = parent || own
    traceparent = "00-#{trace}-#{parent_hex}-01"

    # Erlang API: the W3C propagator and context modules have no Elixir wrapper.
    :otel_propagator_text_map.extract_to(
      :otel_ctx.new(),
      :otel_propagator_trace_context,
      [{"traceparent", traceparent}]
    )
  end

  defp kind(k) when k in [:internal, :server, :client], do: k
  defp kind(_), do: :internal

  # Only an error span gets a status set; success/unset spans keep OTel's
  # default UNSET — the idiomatic OTel representation of "completed, no error",
  # which is what the capture layer's :ok means (it sets :ok for result :ok OR
  # nil). Setting OTel OK would over-claim an explicit success override.
  defp maybe_set_status(span_ctx, %Span{status: :error} = span) do
    OpenTelemetry.Span.set_status(
      span_ctx,
      OpenTelemetry.status(:error, span.status_message || "")
    )
  end

  defp maybe_set_status(_span_ctx, _span), do: :ok

  defp attributes(%Span{} = span) do
    span.attributes
    |> coerce_map()
    |> put_present("image_pipe.pid", span.pid, &inspect/1)
    |> put_present("image_pipe.node", span.node, &Atom.to_string/1)
  end

  # Oneshot event :time is raw monotonic — pass through UNCONVERTED. Exception
  # event (no :time) uses native_end (same frame as the span). event/3 is
  # timestamp-FIRST.
  defp events(%Span{events: events}, native_end) do
    Enum.map(events, fn ev ->
      ts = Map.get(ev, :time) || native_end
      OpenTelemetry.event(ts, ev[:name], event_attrs(ev))
    end)
  end

  # The capture layer folds exceptions as %{name: "exception", attributes:
  # %{kind:, reason:}}; map them onto OTel exception semantic-convention keys.
  defp event_attrs(%{name: "exception", attributes: a}) do
    %{"exception.type" => to_str(a[:kind]), "exception.message" => to_str(a[:reason])}
  end

  defp event_attrs(ev), do: coerce_map(Map.get(ev, :attributes, %{}))

  defp put_present(map, _key, nil, _fun), do: map
  defp put_present(map, key, value, fun), do: Map.put(map, key, fun.(value))

  # OTel attribute values must be primitives; the public set path silently DROPS
  # others, so coerce to keep them. Sensitivity handled upstream by Capture.safe_attrs/1.
  defp coerce_map(map) do
    map
    |> Enum.flat_map(fn {k, v} ->
      case coerce(v) do
        :__drop__ -> []
        cv -> [{k, cv}]
      end
    end)
    |> Map.new()
  end

  defp coerce(nil), do: :__drop__
  defp coerce(v) when is_boolean(v), do: v
  defp coerce(v) when is_number(v) or is_binary(v), do: v
  defp coerce(v) when is_atom(v), do: Atom.to_string(v)

  defp coerce(v) when is_list(v) do
    if Enum.all?(v, &scalar_primitive?/1) do
      Enum.map(v, &list_elem/1)
    else
      inspect(v)
    end
  end

  defp coerce(v), do: inspect(v)

  defp scalar_primitive?(v), do: is_binary(v) or is_atom(v) or is_number(v)

  defp list_elem(v) when is_binary(v), do: v
  defp list_elem(v) when is_atom(v), do: Atom.to_string(v)
  defp list_elem(v) when is_number(v), do: to_string(v)

  defp to_str(nil), do: ""
  defp to_str(v) when is_binary(v), do: v
  defp to_str(v) when is_atom(v), do: Atom.to_string(v)
  defp to_str(v), do: inspect(v)
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/otel_replay_test.exs`
Expected: PASS (all 11).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/telemetry/trace/otel_replay.ex test/image_pipe/telemetry/trace/otel_replay_test.exs
git commit -m "feat(telemetry): OTel replay buffer with top-down parent reconstruction"
```

---

### Task 3: Rewire the exporter through `OtelReplay`; supervise it

**Files:**
- Modify: `lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex` (slim to a facade)
- Modify: `lib/image_pipe/telemetry.ex:10-21` (boundary exports)
- Modify: `lib/application.ex` (boundary dep + child)
- Test: `test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs`
- Test: `test/image_pipe/telemetry/trace/otel_replay_test.exs` (global-instance reset in setup)

- [ ] **Step 1: Adapt the exporter unit tests to buffered semantics**

In `test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs`:

1. Add a reset of the globally-named replay server to `setup` (spans now flow `export/1 → cast → OtelReplay`; per the test-isolation contract, the reset call also fences pending casts from a prior test):

```elixir
  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    ImagePipe.Telemetry.Trace.OtelReplay.reset()
    :ok
  end
```

2. Root detection is flag-only, so every hand-built span that must flush immediately needs `root: true`. Add it to the `base_span/1` defaults:

```elixir
  defp base_span(overrides) do
    Map.merge(
      %Span{
        trace_id: "0123456789abcdef0123456789abcdef",
        span_id: "89abcdef01234567",
        name: "image_pipe.request",
        start_time: System.system_time(),
        duration_native: 1,
        status: :ok,
        trace_flags: 1,
        root: true
      },
      overrides
    )
  end
```

3. The first test (`"replays a span carrying OUR trace_id, ..."`) hand-builds its own span with `parent_span_id: "fedcba9876543210"` — it models the inbound-continued root, so add `root: true` to that struct literal as well:

```elixir
    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      parent_span_id: "fedcba9876543210",
      name: "image_pipe.request",
      kind: :server,
      start_time: System.system_time(),
      duration_native: 1_000,
      status: :ok,
      trace_flags: 1,
      root: true
    }
```

All its assertions stay valid (the root replays via the synthetic traceparent carrying the real upstream parent id).

- [ ] **Step 2: Run the exporter tests to confirm the expected failure mode**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs`
Expected: FAIL — `OtelReplay.reset/0` call fails (no globally-named server running yet). This drives the supervision change.

- [ ] **Step 3: Slim the exporter to a facade**

Replace the body of `lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex` with:

```elixir
defmodule ImagePipe.Telemetry.Trace.OpenTelemetryExporter do
  @moduledoc """
  Opt-in `ImagePipe.Telemetry.Trace.Exporter` that replays finished `%Trace.Span{}`
  structs into a host-running OpenTelemetry SDK using the **public** OTel API.

  Spans are buffered per trace and replayed top-down when the trace's root span
  finishes, so children are parented onto their parent's real OTel-minted span
  context and the full hierarchy survives into Jaeger/Tempo. Correlation with
  logs (`LogExporter`) is trace-level: both share the `trace_id` (forced onto
  the OTel trace via a synthetic W3C remote parent on the root span); OTel
  mints its own span ids, so `span=` ids in log lines do not match OTel span ids.

  Optional dependency `:opentelemetry_api` (compile); the host brings the SDK
  (`:opentelemetry`) and starts it. When the API is absent, `ready?/0` is `false`
  and `attach_tracer/1` raises. When the API is present but the SDK isn't started,
  the API degrades to a noop tracer and this produces nothing — no crash.
  """
  @behaviour ImagePipe.Telemetry.Trace.Exporter

  alias ImagePipe.Telemetry.Trace.{OtelReplay, Span}

  @otel_api_loaded Code.ensure_loaded?(:otel_tracer)

  @doc "Whether the OpenTelemetry API is compiled in."
  @spec available?() :: boolean()
  def available?, do: @otel_api_loaded

  @impl true
  @spec ready?() :: boolean()
  def ready?, do: @otel_api_loaded

  @impl true
  @spec export(Span.t()) :: :ok
  def export(%Span{} = span) do
    if @otel_api_loaded do
      OtelReplay.add(span)
    end

    :ok
  end
end
```

(The `@compile {:no_warn_undefined, ...}` list and all conversion helpers now live only in `OtelReplay`.)

- [ ] **Step 4: Supervise `OtelReplay` and align boundaries**

In `lib/image_pipe/telemetry.ex`, add `Trace.OtelReplay` to the boundary exports. The export exists solely so `ImagePipe.Application` can supervise the module (Boundary counts any module reference); `OtelReplay` stays `@moduledoc false` — an exported-but-internal module, the same posture as the already-exported `Trace.Stack`:

```elixir
  use Boundary,
    top_level?: true,
    deps: [],
    exports: [
      Trace,
      Trace.Stack,
      Trace.Context,
      Trace.Span,
      Trace.Exporter,
      Trace.ReqStep,
      Trace.OpenTelemetryExporter,
      Trace.OtelReplay
    ]
```

In `lib/application.ex` (the replay buffer is listed first so it is up before the first request can emit spans):

```elixir
defmodule ImagePipe.Application do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Output,
      ImagePipe.Request,
      ImagePipe.Telemetry
    ]

  use Application

  require Logger

  alias ImagePipe.Output.Capabilities

  @impl true
  def start(_type, _args) do
    Capabilities.probe()

    children = [
      ImagePipe.Telemetry.Trace.OtelReplay,
      ImagePipe.Request.SourceSessionSupervisor
    ]

    opts = [strategy: :one_for_one, name: ImagePipe.Supervisor]

    Logger.info("Starting application...")
    Supervisor.start_link(children, opts)
  end
end
```

- [ ] **Step 5: Apply the test-isolation contract to `otel_replay_test.exs`**

Now that a globally-named instance exists, add the global reset to its `setup` (before starting the private instance):

```elixir
  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    OtelReplay.reset()

    server =
      start_supervised!(
        {OtelReplay, name: :"otel_replay_#{System.unique_integer([:positive])}"}
      )

    {:ok, server: server}
  end
```

- [ ] **Step 6: Run the affected suites**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs test/image_pipe/telemetry/trace/otel_replay_test.exs test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs test/image_pipe/architecture_boundary_test.exs`
Expected: PASS.

- [ ] **Step 7: Compile with warnings as errors (boundary check runs at compile)**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex lib/image_pipe/telemetry.ex lib/application.ex test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs test/image_pipe/telemetry/trace/otel_replay_test.exs
git commit -m "feat(telemetry): route OTel export through the replay buffer"
```

---

### Task 4: E2E hierarchy regression test (the Jaeger bug)

**Files:**
- Test: `test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs`

- [ ] **Step 1: Apply the test-isolation contract to the integration test**

Replace the file's `setup` block in full:

```elixir
  # Route OTel spans to the test process; next test's setup re-points the exporter.
  # Resetting the replay buffer also fences pending casts from a prior test.
  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    ImagePipe.Telemetry.Trace.OtelReplay.reset()
    :ok
  end
```

- [ ] **Step 2: Make test 1's hand-built span a root**

Test 1 (`"LogExporter and OTel share the trace_id; ..."`) hand-builds a nil-parent span and calls `export/1` directly. Root detection is flag-only, so add `root: true` to its struct literal (the span models a request root):

```elixir
    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      name: "image_pipe.request",
      kind: :server,
      start_time: System.system_time(),
      duration_native: 1,
      status: :ok,
      trace_flags: 1,
      root: true
    }
```

- [ ] **Step 3: Add the regression test**

Add after test 2:

```elixir
  # ── test 4: hierarchy — the Jaeger "missing parent spans" regression ──────────
  #
  # Pre-fix, every exported span referenced an internal (never-exported) parent id,
  # so Jaeger flagged all spans as missing their parent and rendered the trace flat.
  # Post-fix, every non-root span must point at another exported span's OTel-minted
  # id; only the request root keeps a synthetic out-of-trace parent (it forces
  # ImagePipe's trace_id).

  test "every non-root span parents onto another exported span" do
    attach_otel_tracer()

    conn = call(request_path(), miss_opts())
    assert conn.status == 200

    # A synchronous call fences every add/2 cast enqueued before it; the drain
    # window covers cross-process spans still finishing after the response.
    :ok = ImagePipe.Telemetry.Trace.OtelReplay.sweep()

    recs = drain_spans()
    assert recs != [], "no spans exported — request/drain not wired"

    req = Enum.find(recs, &(otel_span(&1, :name) == "image_pipe.request"))
    assert req, "request root span missing"

    trace_id = otel_span(req, :trace_id)
    trace_recs = Enum.filter(recs, &(otel_span(&1, :trace_id) == trace_id))
    assert length(trace_recs) >= 3

    minted = MapSet.new(trace_recs, &otel_span(&1, :span_id))

    dangling =
      Enum.reject(trace_recs, fn rec ->
        MapSet.member?(minted, otel_span(rec, :parent_span_id))
      end)

    assert dangling == [req]
  end
```

- [ ] **Step 4: Run it**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs`
Expected: PASS. (If it fails with spans missing from `trace_recs`, the replay path has a bug — do not loosen the assertion.)

- [ ] **Step 5: Commit**

```bash
git add test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs
git commit -m "test(telemetry): pin OTel parent hierarchy end-to-end"
```

---

### Task 5: Documentation

**Files:**
- Modify: `docs/telemetry.md` ("OpenTelemetry export" section, ~line 562)
- Modify: `docs/cookbook/opentelemetry-jaeger.md` (step 4 wording)

- [ ] **Step 1: Update `docs/telemetry.md`**

Replace the **"Correlation is trace-level:"** paragraph with:

```markdown
**Hierarchy and correlation:** spans are buffered per trace and replayed into the
SDK top-down when the request's root span finishes, so every child is parented
onto its parent's OTel-minted span context — the full span tree survives into
Jaeger/Tempo. (The replay buffer is a GenServer supervised by ImagePipe's
application; it is inert unless this exporter is attached, and best-effort:
buffered traces are dropped on crash/shutdown, and under extreme load spans for
new traces are shed rather than growing without bound.) Correlation with logs
is trace-level: logs and OTel spans share the `trace_id`; OTel mints its own
span ids, so the `span=` ids in `LogExporter` lines will not match OTel span
ids. When ImagePipe is *not* the originating tracer (`extract_inbound: true`
behind a traced caller), the root span is a real child of the caller. As the
originator, only the root carries a synthetic "remote parent" (it forces
ImagePipe's `trace_id` onto the OTel trace) — at most one out-of-trace parent
reference per trace, on the root. Traces whose root never finishes (the
emitting process died) are flushed flat after ~10 s, each span keeping its
recorded parent id; spans finishing shortly after the root (cross-process
stages) still parent correctly within the same window, except a late span
whose own parent is also late and not yet replayed, which falls back to a
dangling parent. One cosmetic side effect of forcing the `trace_id`: every
replayed span is marked as having a *remote* parent (`parent_span_is_remote`),
because the OTel SDK propagates the root's synthetic remote-parent flag down
the tree. Hierarchy and trace identity are unaffected, but a `parent_based`
sampler that treats remote and local parents differently will take its
remote-parent branch for all ImagePipe spans — keep both branches on the same
policy. If `:opentelemetry_api` is absent, `attach_tracer/1` raises;
if present but the SDK isn't started, spans are silently dropped by the noop
tracer (start the SDK). See `docs/cookbook/opentelemetry-jaeger.md`.
```

(Keep the **"Forced sampled flag:"** paragraph as is.)

- [ ] **Step 2: Update the cookbook**

In `docs/cookbook/opentelemetry-jaeger.md` step 4, replace the closing paragraph:

```markdown
If `:opentelemetry_api` isn't present this raises at startup. Issue a request, wait a
few seconds for the batch processor to flush, then find the `image_pipe.request` trace
in Jaeger — child spans (`image_pipe.{send,encode,output.negotiate,transform.execute,
transform.operation,…}`) are nested under it. The root span itself may show a
"missing parent" note in Jaeger when ImagePipe originates the trace: its synthetic
remote parent is what forces ImagePipe's `trace_id` onto the OTel trace (use
`extract_inbound: true` behind a traced caller to make it a real child instead).
```

- [ ] **Step 3: Commit**

```bash
git add docs/telemetry.md docs/cookbook/opentelemetry-jaeger.md
git commit -m "docs(telemetry): describe OTel replay hierarchy and root semantics"
```

---

### Task 6: Full gate

- [ ] **Step 1: Run the precommit gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all pass.

- [ ] **Step 2: Fix anything it surfaces, re-run until clean, commit fixes**

Stage the specific files the gate touched (no `git add -A`):

```bash
git add <each fixed file by path>
git commit -m "chore: precommit fixes for OTel replay hierarchy"
```

(Skip the commit if the gate is clean with nothing to fix.)

---

## Out of scope / explicitly not done

- **No change to the `Exporter` behaviour** — it stays span-at-a-time; buffering is an `OtelReplay` implementation detail. `LogExporter` and `TestExporter` are untouched.
- **No Logger (`ImagePipe.Telemetry.Logger`) changes** — no telemetry event was added, removed, renamed, or re-meta'd; the new `Span.root` field is exporter-facing, not an event change, and does not appear in the `LogExporter` line format.
- **No re-buffering of late-child-before-late-parent arrivals** — documented degradation (design decision 5); the realistic window is milliseconds.
- **No `is_remote` re-anchoring** — replayed children visibly inherit `parent_span_is_remote: true`; cosmetic, documented (design decision 4).
- **No imgproxy conformance-doc change** — OTel export is host observability, not a compatibility-target behavior.
- **No cache-key/ETag interaction** — telemetry only.
- **`detach_tracer/0` does not reset `OtelReplay`** — buffered spans simply expire via TTL; tests that need isolation call `OtelReplay.reset/0`.
