# OpenTelemetry Trace-Level Export — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development (or executing-plans). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Ship an opt-in `Trace.Exporter` that replays #175's finished `%Trace.Span{}` structs into a host-running OpenTelemetry SDK via the **public** OTel API, preserving the **trace_id** (trace-level correlation; OTel mints span_ids).

**Architecture:** `ImagePipe.Telemetry.Trace.OpenTelemetryExporter` (a `Trace.Exporter`, sibling to `LogExporter`) — for each finished span: build a remote-parent context from a synthetic W3C `traceparent` carrying our trace_id, `start_span(ctx, …)` with explicit start_time, set status/attributes/events, `end_span(_, end_time)`. OTel-referencing code sits behind a compile guard on `OpenTelemetry.Tracer` so hosts without `:opentelemetry_api` still compile. No SDK internals, no FFI.

**Tech Stack:** Elixir, `:opentelemetry_api` (optional, compile), `:opentelemetry` SDK (`only: :test`), `:telemetry`, ExUnit. Public-API mechanics verified against opentelemetry-erlang `opentelemetry_api` 1.5 / `opentelemetry` 1.7.

**Design:** `docs/superpowers/specs/2026-06-09-opentelemetry-trace-level-export-design.md`

---

## Verified interop facts (do not guess)

- All calls are `:opentelemetry_api` (host brings SDK at runtime). Elixir wrappers: `OpenTelemetry.Tracer.start_span/3` (macro; `require`d; ctx-first; injects `get_application_tracer`), `OpenTelemetry.Span.set_status/2`/`add_events/2`/`end_span/2`, `OpenTelemetry.status/2`, `OpenTelemetry.event/3` (**timestamp-FIRST**). Erlang-direct (no wrapper): `:otel_propagator_text_map.extract_to/3` + `:otel_propagator_trace_context`, `:otel_ctx.new/0`.
- **Out-of-band export works**: a span from `start_span(ctx,…)` ended via `Span.end_span(span_ctx, ts)` flows to the exporter without being the current span. **Thread the SDK-returned `span_ctx`** through all setters/end.
- **`-01` sampled flag is MANDATORY** in the synthetic traceparent (`-00` → silently dropped).
- **Time frames (the trap):** span `start_time`/`end_time` come from #175's `system_time` → convert `native = system_time - :erlang.time_offset()`. Oneshot event `:time` is *already* `monotonic_time` → **pass through UNCONVERTED**. Exception event (no `:time`) → use the converted `native_end`.
- `extract_to/3` (not `extract/2` — which mutates process ctx). Root (`parent_span_id` nil) uses its own `span_id` as the synthetic parent (dangling remote-parent rendering — accepted).
- Public `set_attributes`/`add_event` validate+**drop** non-primitive values → coerce structs→`inspect` strings first.
- `%Trace.Span{}` fields (#175): `trace_id`/`span_id` hex strings, `parent_span_id` hex or nil; `kind` `:internal|:server|:client|nil`; `status` `:unset|:ok|:error|nil` + `status_message`; `start_time` native system_time; `duration_native` native delta; `events` `[%{name:, time:, attributes:}]` (exception event = `%{name: "exception", attributes: %{kind:, reason:}}`, no `:time`); `pid`, `node`; `trace_flags` default 1.

## File structure

- **Modify** `mix.exs` — `:opentelemetry_api` optional (compile) + `:opentelemetry` `only: :test`; docs/package lists (Task 7).
- **Modify** `config/config.exs` — test-env OTel SDK config.
- **Modify** `lib/image_pipe/telemetry/trace/exporter.ex` — optional `c:ready?/0` callback.
- **Create** `lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex` — the exporter (compile-guarded).
- **Modify** `lib/image_pipe/telemetry.ex` — `attach_tracer/1` `ready?/0` probe; boundary `exports:`.
- **Create** `test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs`.
- **Create** `test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs`.
- **Create** `docs/cookbook/opentelemetry-jaeger.md`; **Modify** `docs/telemetry.md`, `CLAUDE.md`.

---

## Task 1: Deps + test config

**Files:** Modify `mix.exs` (deps), `config/config.exs`.

- [ ] **Step 1: Add deps.** In `mix.exs` `defp deps` `base` list, after `{:telemetry, "~> 1.0"},`:

```elixir
      # Opt-in OpenTelemetry export. Compile against the lightweight API only
      # (optional: true, NO `only:` — the optional edge orders a host-provided
      # opentelemetry_api before image_pipe so the compile guard activates). The
      # SDK is the host's at runtime; we pull it only for our own tests.
      {:opentelemetry_api, "~> 1.5", optional: true},
      {:opentelemetry, "~> 1.7", only: :test},
```

- [ ] **Step 2: Test-env SDK config.** Replace `config/config.exs` body:

```elixir
import Config

# config :image_pipe, ImagePipe, ...

if config_env() == :test do
  # Synchronous simple processor, no real exporter; tests swap in a pid exporter
  # per-test via :otel_simple_processor.set_exporter/2.
  config :opentelemetry,
    span_processor: :simple,
    traces_exporter: :none
end
```

- [ ] **Step 3:** `mise exec -- mix deps.get` (resolves opentelemetry_api 1.5.x + opentelemetry 1.7.x; mix.lock updated).
- [ ] **Step 4:** `mise exec -- mix compile` (clean) and `MIX_ENV=test mise exec -- mix compile` (clean).
- [ ] **Step 5: Commit.**
```bash
git add mix.exs mix.lock config/config.exs
git commit -m "build(telemetry): add opentelemetry_api (optional) + SDK (test) for OTel export"
```

---

## Task 2: `ready?/0` optional callback on the Exporter behaviour

**Files:** Modify `lib/image_pipe/telemetry/trace/exporter.ex`.

- [ ] **Step 1:** Append before the final `end` (after `@callback export(Span.t()) :: :ok`):

```elixir
  @doc """
  Optional readiness gate, consulted by `ImagePipe.Telemetry.attach_tracer/1`.

  Return `false` when the exporter cannot run (e.g. an optional backend dependency
  is not loaded). `attach_tracer/1` raises `ArgumentError` instead of attaching,
  turning a missing dependency into an actionable startup error rather than a
  per-request crash. Exporters that omit this callback are always considered ready.
  """
  @callback ready?() :: boolean()

  @optional_callbacks ready?: 0
```

- [ ] **Step 2:** `mise exec -- mix compile --warnings-as-errors` (PASS; LogExporter need not implement it).
- [ ] **Step 3: Commit.**
```bash
git add lib/image_pipe/telemetry/trace/exporter.ex
git commit -m "feat(telemetry): add optional Trace.Exporter ready?/0 callback"
```

---

## Task 3: The exporter (public-API replay) + canary (verify-first)

**Files:** Create `lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex`, `test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs`.

> Keystone. The public-API mechanics are verified against real OTel but not yet *run*. If the canary fails in a way a small fix can't resolve, report **BLOCKED** with the exact error — do not thrash.

- [ ] **Step 1: Write the failing canary test.** Create `test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs`:

```elixir
defmodule ImagePipe.Telemetry.Trace.OpenTelemetryExporterTest do
  use ExUnit.Case, async: false

  require Record
  # Read the #span{} the SDK delivers (test-only — reading, not constructing).
  Record.defrecordp(
    :otel_span,
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  alias ImagePipe.Telemetry.Trace.{OpenTelemetryExporter, Span}

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    on_exit(fn -> :otel_simple_processor.set_exporter(:none, []) end)
    :ok
  end

  test "replays a span carrying OUR trace_id, with an OTel-minted (different) span_id" do
    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      parent_span_id: "fedcba9876543210",
      name: "image_pipe.request",
      kind: :server,
      start_time: System.system_time(),
      duration_native: 1_000,
      status: :ok,
      trace_flags: 1
    }

    assert :ok = OpenTelemetryExporter.export(span)

    assert_receive {:span, rec}, 1_000
    # OUR trace_id is preserved (integer-decoded).
    assert otel_span(rec, :trace_id) == 0x0123456789ABCDEF0123456789ABCDEF
    # OTel minted its OWN span_id — non-zero and NOT our span_id (the trace-level trade).
    minted = otel_span(rec, :span_id)
    assert is_integer(minted) and minted != 0
    assert minted != 0x89ABCDEF01234567
    # parent is the remote parent we supplied (our parent_span_id).
    assert otel_span(rec, :parent_span_id) == 0xFEDCBA9876543210
    assert otel_span(rec, :name) == "image_pipe.request"
    assert otel_span(rec, :kind) == :server
  end
end
```

- [ ] **Step 2:** Run; expect FAIL (module undefined): `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs`

- [ ] **Step 3: Implement the exporter.** Create `lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex`:

```elixir
defmodule ImagePipe.Telemetry.Trace.OpenTelemetryExporter do
  @moduledoc """
  Opt-in `ImagePipe.Telemetry.Trace.Exporter` that replays finished `%Trace.Span{}`
  structs into a host-running OpenTelemetry SDK using the **public** OTel API.

  Correlation is **trace-level**: logs (`LogExporter`) and OTel spans share the
  `trace_id`, not the `span_id` (OTel mints its own). We force our `trace_id` onto
  each span via a synthetic W3C `traceparent` remote parent; the span's own id is
  OTel's. No SDK internals.

  Optional dependency `:opentelemetry_api` (compile); the host brings the SDK
  (`:opentelemetry`) and starts it. When the API is absent, `ready?/0` is `false`
  and `attach_tracer/1` raises. When the API is present but the SDK isn't started,
  the API degrades to a noop tracer and this produces nothing — no crash.

  See `docs/superpowers/specs/2026-06-09-opentelemetry-trace-level-export-design.md`.
  """
  @behaviour ImagePipe.Telemetry.Trace.Exporter

  alias ImagePipe.Telemetry.Trace.Span

  if Code.ensure_loaded?(OpenTelemetry.Tracer) do
    require OpenTelemetry.Tracer, as: Tracer
    alias OpenTelemetry.Span, as: OtelSpan

    @doc "Whether the OpenTelemetry API is compiled in."
    @spec available?() :: boolean()
    def available?, do: Code.ensure_loaded?(OpenTelemetry.Tracer)

    @impl true
    @spec ready?() :: boolean()
    def ready?, do: available?()

    @impl true
    @spec export(Span.t()) :: :ok
    def export(%Span{} = span) do
      offset = :erlang.time_offset()
      native_start = (span.start_time || 0) - offset
      native_end = native_start + (span.duration_native || 0)

      span_ctx =
        Tracer.start_span(parent_ctx(span), span.name, %{
          start_time: native_start,
          kind: kind(span.kind),
          attributes: attributes(span),
          links: []
        })

      OtelSpan.set_status(span_ctx, status(span))

      case events(span, native_end) do
        [] -> :ok
        evs -> OtelSpan.add_events(span_ctx, evs)
      end

      OtelSpan.end_span(span_ctx, native_end)
      :ok
    end

    # Force OUR trace_id via a synthetic remote parent. Root (nil parent) uses its
    # own span_id as the (dangling) synthetic parent. -01 sampled flag is mandatory.
    defp parent_ctx(%Span{trace_id: trace, parent_span_id: parent, span_id: own}) do
      parent_hex = parent || own
      traceparent = "00-#{trace}-#{parent_hex}-01"

      :otel_propagator_text_map.extract_to(
        :otel_ctx.new(),
        :otel_propagator_trace_context,
        [{"traceparent", traceparent}]
      )
    end

    defp kind(k) when k in [:internal, :server, :client], do: k
    defp kind(_), do: :internal

    defp status(%Span{status: :error} = span),
      do: OpenTelemetry.status(:error, span.status_message || "")

    defp status(%Span{status: :ok}), do: OpenTelemetry.status(:ok, "")
    defp status(_), do: OpenTelemetry.status(:unset, "")

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

    # #175's exception event: %{name: "exception", attributes: %{kind:, reason:}}.
    # Map to OTel exception semantics.
    defp event_attrs(%{name: "exception", attributes: a}) do
      %{"exception.type" => to_str(a[:kind]), "exception.message" => to_str(a[:reason])}
    end

    defp event_attrs(ev), do: coerce_map(Map.get(ev, :attributes, %{}))

    defp put_present(map, _key, nil, _fun), do: map
    defp put_present(map, key, value, fun), do: Map.put(map, key, fun.(value))

    # OTel attribute values must be primitives; the public set path silently DROPS
    # others, so coerce to keep them. Sensitivity is handled upstream by
    # Capture.safe_attrs/1 — type concern only.
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
    defp coerce(v), do: inspect(v)

    defp to_str(nil), do: ""
    defp to_str(v) when is_binary(v), do: v
    defp to_str(v), do: inspect(v)
  else
    @doc "OpenTelemetry API not compiled in; this exporter is a no-op."
    @spec available?() :: boolean()
    def available?, do: false

    @impl true
    @spec ready?() :: boolean()
    def ready?, do: false

    @impl true
    @spec export(Span.t()) :: :ok
    def export(%Span{}), do: :ok
  end
end
```

- [ ] **Step 4: Add the boundary export now** (the test aliases the module across the boundary, so Boundary requires it to compile). In `lib/image_pipe/telemetry.ex`, add `Trace.OpenTelemetryExporter` to the `exports:` list (around line 13).

- [ ] **Step 5:** Run the canary: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs` — expect PASS. If FAIL and unfixable by a small correction, report BLOCKED with the exact error.

- [ ] **Step 6:** `mise exec -- mix format` then `mise exec -- mix compile --warnings-as-errors` (clean).

- [ ] **Step 7: Commit.**
```bash
git add lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex lib/image_pipe/telemetry.ex test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs
git commit -m "feat(telemetry): OpenTelemetry exporter — public-API replay preserving trace_id"
```

---

## Task 4: Mapping fidelity tests

**Files:** Modify `test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs`. Append these (the `otel_span(...)` macro + `Span`/`OpenTelemetryExporter` aliases are in scope; the attributes wrapper record is `{:attributes, count_limit, value_length_limit, dropped, map}`, raw map = `elem(_, 4)`).

- [ ] **Step 1: Add tests.**

```elixir
  test "duration survives: exported end - start == duration_native" do
    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      name: "image_pipe.transform.execute",
      kind: :internal,
      start_time: System.system_time(),
      duration_native: 5_000,
      status: :ok,
      trace_flags: 1
    }

    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :end_time) - otel_span(rec, :start_time) == 5_000
  end

  test "maps error status with its message" do
    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      name: "image_pipe.source.fetch",
      kind: :client,
      start_time: System.system_time(),
      duration_native: 1,
      status: :error,
      status_message: "boom",
      trace_flags: 1
    }

    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :status) == {:status, :error, "boom"}
  end

  test "coerces non-primitive attributes, adds pid/node, drops nils" do
    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      name: "image_pipe.transform.operation",
      kind: :internal,
      start_time: System.system_time(),
      duration_native: 1,
      status: :ok,
      trace_flags: 1,
      pid: self(),
      node: node(),
      attributes: %{width: 100, result: :ok, params: 1..3, dropme: nil}
    }

    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, rec}, 1_000

    attrs = elem(otel_span(rec, :attributes), 4)
    assert attrs[:width] == 100
    assert attrs[:result] == "ok"
    assert attrs[:params] == inspect(1..3)
    refute Map.has_key?(attrs, :dropme)
    assert attrs["image_pipe.pid"] == inspect(self())
    assert attrs["image_pipe.node"] == Atom.to_string(node())
  end

  test "span exports with the mandatory -01 sampled flag (regression guard)" do
    # A regression to -00 in parent_ctx/1 would make the parent_based sampler drop
    # the span and this refute_receive would NOT fire (the span never arrives).
    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      name: "image_pipe.request",
      kind: :server,
      start_time: System.system_time(),
      duration_native: 1,
      status: :ok,
      trace_flags: 1
    }

    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, _rec}, 1_000
  end

  test "a oneshot event lands inside its span's [start, end] window (frame guard)" do
    # Oneshot event :time is raw monotonic and must NOT get the time_offset
    # subtraction the span start/end get; a uniform conversion would push it hours
    # out of the window. We read the event timestamp off the exported #span{}.
    start = System.system_time()
    event_mono = :erlang.monotonic_time()

    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      name: "image_pipe.cache.lookup",
      kind: :internal,
      start_time: start,
      duration_native: 1_000_000,
      status: :ok,
      trace_flags: 1,
      events: [%{name: "image_pipe.cache.stage", time: event_mono, attributes: %{cache: :hit}}]
    }

    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, rec}, 1_000

    [event] = otel_span(rec, :events) |> events_list()
    ev_ts = event_system_time_native(event)
    assert ev_ts >= otel_span(rec, :start_time)
    assert ev_ts <= otel_span(rec, :end_time)
  end

  test "export/1 is crash-safe and emits nothing when OTel can't deliver" do
    :otel_simple_processor.set_exporter(:none, [])

    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      name: "image_pipe.request",
      start_time: System.system_time(),
      duration_native: 1,
      status: :ok,
      trace_flags: 1
    }

    assert :ok = OpenTelemetryExporter.export(span)
    refute_receive {:span, _}, 100
  end
```

> **Executor note (event reading):** the `#span{}` `events` field is an `otel_events:t()` wrapper, and each `#event{}` carries a `system_time_native` field. Add two tiny test helpers — `events_list/1` to pull the `list` out of the events wrapper, and `event_system_time_native/1` to pull the timestamp off an `#event{}` — using `Record.defrecordp` on `:events`/`:event` from `opentelemetry/include/otel_span.hrl` (same header), or `elem/2` by position with a comment. Confirm the exact field positions when you wire it; the assertion (event timestamp within span window) is the contract.

- [ ] **Step 2:** `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs` — all pass. If the oneshot-window test fails, the time-frame handling in `events/2` is wrong (likely a stray conversion) — fix the exporter, not the test. Then `mix format` + `mix compile --warnings-as-errors`.
- [ ] **Step 3: Commit.**
```bash
git add test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs
git commit -m "test(telemetry): OTel mapping fidelity — duration, status, coercion, sampled-flag, event frame, undeliverable"
```

---

## Task 5: `attach_tracer` readiness probe + gate test

**Files:** Modify `lib/image_pipe/telemetry.ex`, `test/image_pipe/telemetry/trace/attach_test.exs`.

- [ ] **Step 1: Failing gate test.** Add to `attach_test.exs` (the existing #175 attach-tracer tests; confirm path with `grep -rl attach_tracer test/`). Inline not-ready exporter so it doesn't depend on OTel absence:

```elixir
  defmodule NotReadyExporter do
    @behaviour ImagePipe.Telemetry.Trace.Exporter
    @impl true
    def export(_span), do: :ok
    @impl true
    def ready?, do: false
  end

  test "attach_tracer raises when the exporter reports not ready" do
    assert_raise ArgumentError, ~r/not ready/, fn ->
      ImagePipe.Telemetry.attach_tracer(exporter: NotReadyExporter)
    end
  end
```

- [ ] **Step 2:** Run; expect FAIL: `mise exec -- mix test test/image_pipe/telemetry/trace/attach_test.exs`
- [ ] **Step 3: Add the probe.** In `lib/image_pipe/telemetry.ex`, immediately after the existing `unless Code.ensure_loaded?(exporter) … end` block (~line 135-138), insert:

```elixir
    if function_exported?(exporter, :ready?, 0) and not exporter.ready?() do
      raise ArgumentError,
            "exporter #{inspect(exporter)} is not ready: ready?/0 returned false " <>
              "(for OpenTelemetryExporter, add :opentelemetry to your host deps)"
    end
```

- [ ] **Step 4:** `mise exec -- mix test test/image_pipe/telemetry/trace/attach_test.exs` — PASS. `mix compile --warnings-as-errors`.
- [ ] **Step 5: Commit.**
```bash
git add lib/image_pipe/telemetry.ex test/image_pipe/telemetry/trace/attach_test.exs
git commit -m "feat(telemetry): attach_tracer raises on a not-ready exporter"
```

---

## Task 6: E2E + cross-consumer correlation + URL safety

**Files:** Create `test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs`.

- [ ] **Step 1: Correlation test (focused, no real request).** This proves the relaxed product requirement. Create the file:

```elixir
defmodule ImagePipe.Telemetry.Trace.OpenTelemetryIntegrationTest do
  use ExUnit.Case, async: false

  require Record
  Record.defrecordp(
    :otel_span,
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.{LogExporter, OpenTelemetryExporter, Span}

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    on_exit(fn -> :otel_simple_processor.set_exporter(:none, []) end)
    :ok
  end

  test "LogExporter and OTel share the trace_id; span_ids DIFFER (trace-level trade)" do
    import ExUnit.CaptureLog

    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      name: "image_pipe.request",
      kind: :server,
      start_time: System.system_time(),
      duration_native: 1,
      status: :ok,
      trace_flags: 1
    }

    assert :ok = OpenTelemetryExporter.export(span)
    assert_receive {:span, rec}, 1_000
    log = capture_log(fn -> LogExporter.export(span) end)

    # Same trace (the join key): log hex ↔ OTel integer-decoded.
    assert log =~ "trace=#{span.trace_id}"
    assert String.to_integer(span.trace_id, 16) == otel_span(rec, :trace_id)

    # Span ids DIFFER — documents the accepted trace-level trade.
    assert log =~ "span=#{span.span_id}"
    assert String.to_integer(span.span_id, 16) != otel_span(rec, :span_id)
  end
end
```

- [ ] **Step 2: E2E + URL safety.** Add tests that issue a real `ImagePipe.call/2` with the tracer attached, reusing the #175 tracer wire-test fixtures (`grep -rl "attach_tracer\|TestExporter" test/` → likely `test/image_pipe/telemetry/trace/cross_process_test.exs` / `admission_root_test.exs` + `test/support/trace_test_exporter.ex`). Two tests:
  - **One trace_id across the request:** attach `OpenTelemetryExporter`, run the request, drain `{:span, rec}` messages, assert all exported spans share one `trace_id` (no deep-nesting assertion — trace-level).
  - **URL safety:** route through a source whose URL carries `X-Amz-Signature=`; collect every string attribute value across exported spans and assert the signature substring appears in none. **Guard non-vacuity:** `assert collected != []` before the `refute`. Implement the collector as a `raise`-until-wired helper (not a `[]` stub) so the task cannot pass vacuously.

```elixir
  # add inside the module:
  setup do
    Telemetry.attach_tracer(exporter: OpenTelemetryExporter, finch_spans: false)
    on_exit(fn -> Telemetry.detach_tracer() end)
    :ok
  end

  test "a real request exports spans that all share one trace_id" do
    # TODO(executor): issue the same ImagePipe.call/2 the #175 wire test issues
    # (reuse its endpoint opts + stubbed source), then:
    recs = drain_spans()
    assert recs != [], "no spans exported — request/drain not wired"
    trace_ids = recs |> Enum.map(&otel_span(&1, :trace_id)) |> Enum.uniq()
    assert length(trace_ids) == 1
  end

  test "no signed source URL leaks into any exported span attribute" do
    values = collected_attribute_values_after_signed_url_request()
    assert values != [], "no attribute values collected — request/drain not wired"
    refute Enum.any?(values, &String.contains?(&1, "X-Amz-Signature"))
  end

  defp drain_spans(acc \\ []) do
    receive do
      {:span, rec} -> drain_spans([rec | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  # MUST drive a real ImagePipe.call/2 whose source URL contains "X-Amz-Signature="
  # then return every string attribute value across all exported spans:
  #   drain_spans() |> Enum.flat_map(fn r -> elem(otel_span(r, :attributes), 4) |> Map.values() end) |> Enum.filter(&is_binary/1)
  defp collected_attribute_values_after_signed_url_request do
    raise "executor: wire a signed-URL request + collect string attribute values"
  end
```

> The two `setup` blocks in this module must be merged by the executor (ExUnit allows multiple `setup`, but keep the per-test exporter pid + the attach/detach together cleanly). Do **not** ship the URL-safety helper as a `[]` stub.

- [ ] **Step 3:** Run, format, compile-clean.
- [ ] **Step 4: Commit.**
```bash
git add test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs
git commit -m "test(telemetry): e2e one-trace-id + trace-level correlation + url safety"
```

---

## Task 7: Docs, cookbook, guideline carve-out, boundary

**Files:** Modify `docs/telemetry.md`, `CLAUDE.md`, `mix.exs` (docs/package lists); Create `docs/cookbook/opentelemetry-jaeger.md`. (Boundary export was done in Task 3 Step 4.)

- [ ] **Step 1: `docs/telemetry.md`** — under `## Tracing (opt-in)` (`grep -n "Tracing (opt-in)\|attach_tracer" docs/telemetry.md`), add:

```markdown
### OpenTelemetry export

`ImagePipe.Telemetry.Trace.OpenTelemetryExporter` replays captured spans into a
host-running OpenTelemetry SDK via the public OTel API. Optional dependency: ImagePipe
compiles against `:opentelemetry_api` only (declared `optional: true`); the **host**
adds `:opentelemetry` (+ an OTLP exporter) and starts the SDK.

```elixir
# host deps: {:opentelemetry, "~> 1.7"}, {:opentelemetry_exporter, "~> 1.8"}
ImagePipe.Telemetry.attach_tracer(
  exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
  extract_inbound: true
)
```

**Correlation is trace-level:** logs and OTel spans share the `trace_id` (so a trace
groups across logs and traces); OTel mints its own `span_id`. When ImagePipe is *not*
the originating tracer (`extract_inbound: true` behind a traced caller), the root span
is a real child of the caller. As the originator, the root carries a synthetic
"remote parent" — cosmetic. If `:opentelemetry_api` is absent, `attach_tracer/1`
raises; if present but the SDK isn't started, spans are silently dropped by the noop
tracer (start the SDK). See `docs/cookbook/opentelemetry-jaeger.md`.
```

Also soften any "ImagePipe doesn't depend on OpenTelemetry" line to "doesn't *hard*-depend; ships an optional, opt-in OTel exporter (API-only at compile time)".

- [ ] **Step 2: Create `docs/cookbook/opentelemetry-jaeger.md`:**

```markdown
# Cookbook: OpenTelemetry traces to Jaeger (local)

ImagePipe emits `:telemetry` spans and ships an opt-in exporter that replays them into
your OpenTelemetry SDK (preserving ImagePipe's trace_id). This sends traces to a local
Jaeger all-in-one.

## 1. Run Jaeger

```yaml
# docker-compose.yml
services:
  jaeger:
    image: jaegertracing/all-in-one:1.60
    ports: ["16686:16686", "4317:4317", "4318:4318"]
```

`docker compose up -d`, then open http://localhost:16686.

## 2. Add the OTel SDK (host side)

```elixir
# mix.exs
{:opentelemetry, "~> 1.7"},
{:opentelemetry_exporter, "~> 1.8"},
```

ImagePipe itself only needs `:opentelemetry_api` (it declares it optional); you bring
the SDK.

## 3. Point the SDK at Jaeger

```elixir
# config/runtime.exs
config :opentelemetry, span_processor: :batch, traces_exporter: :otlp
config :opentelemetry_exporter, otlp_protocol: :http_protobuf, otlp_endpoint: "http://localhost:4318"
```

Set your `service.name` via `OTEL_RESOURCE_ATTRIBUTES` / the SDK resource — ImagePipe
sets only the `image_pipe` instrumentation scope.

## 4. Activate at startup

```elixir
ImagePipe.Telemetry.attach_tracer(
  exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
  extract_inbound: true
)
```

If `:opentelemetry_api` isn't present this raises at startup. Issue a request and find
the `image_pipe.request` trace in Jaeger.
```

- [ ] **Step 3: CLAUDE.md carve-out.** Find "Keep third-party backend integrations out of the library: hosts attach AppSignal, OpenTelemetry, and metrics handlers themselves." Append:

```
 The one exception is an opt-in, optional-dependency OTel *exporter* (`ImagePipe.Telemetry.Trace.OpenTelemetryExporter`) that ships adapter code only, compiles against `:opentelemetry_api` (optional), is never attached automatically, and uses only the public OTel API — the host still provides the SDK and configures the backend. Preserves "never automatic" and "no hard dep".
```

- [ ] **Step 4: `mix.exs` docs/package lists.** Add `"docs/cookbook/opentelemetry-jaeger.md"` to `docs: [extras: [...]]` (after `"docs/telemetry.md"`) and to `package: [files: [...]]`.

- [ ] **Step 5:** `mise exec -- mix compile --warnings-as-errors` (boundary export resolves). Commit.
```bash
git add lib/image_pipe/telemetry.ex docs/telemetry.md docs/cookbook/opentelemetry-jaeger.md CLAUDE.md mix.exs
git commit -m "docs(telemetry): OTel export docs, Jaeger cookbook, boundary export, guideline carve-out"
```

---

## Task 8: Full gate

- [ ] **Step 1:** `mise exec -- mix test test/image_pipe/telemetry/` — PASS.
- [ ] **Step 2:** `mise run precommit` — format + `compile --warnings-as-errors` + `credo --strict` + `test` all PASS.
- [ ] **Step 3:** Commit any format/credo touch-ups.
```bash
git add -A && git commit -m "chore(telemetry): precommit clean for OTel trace-level export"
```

---

## Self-review notes (carried into execution)

- **Time-frame asymmetry is the #1 correctness trap:** span `start_time`/`end_time` get `- :erlang.time_offset()`; oneshot event `:time` (already monotonic) does NOT. The Task 4 oneshot-window test is the guard — if it fails, the bug is a stray conversion in `events/2`.
- **`-01` sampled flag** in `parent_ctx/1` is load-bearing; the Task 4 "span does arrive" test guards a `-00` regression (which would silently drop everything).
- **Thread the SDK-returned `span_ctx`** through `set_status`/`add_events`/`end_span` — a reconstructed span_ctx no-ops.
- **Compile guard** keys on `OpenTelemetry.Tracer`; all OTel calls (incl. `require`, `extract_to`, the macro) stay inside the `if` branch; the `else` branch is no-op. The exporter never references the SDK package — API only.
- **Trace-level, not span-level:** tests assert OTel mints a *different* span_id and that log/OTel share the trace_id. Don't write a test asserting span_ids are equal.
- **`ready?/0` probe (Task 5) is load-bearing** for the absence story — without it a host missing the API attaches a silent no-op.
- **URL-safety helper must be wired, not stubbed** — the `raise` + `assert values != []` guard enforce non-vacuity.
- Don't write: a `nil`-kind test (no producer emits it), or any module/function-existence test (name-policing).
