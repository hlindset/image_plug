# OpenTelemetry Exporter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an opt-in, optional-dependency `Trace.Exporter` that maps #175's finished `Trace.Span` structs into the host's OpenTelemetry SDK, preserving our trace/span IDs so exported spans stitch to the `traceparent` `ReqStep` already injects.

**Architecture:** A single new module `ImagePipe.Telemetry.Trace.OpenTelemetryExporter` implements `export/1` by hand-constructing the SDK-internal `#span{}` record (there is no public API to record a span with a caller-chosen `span_id`) and running the host's configured span processors over it via the tracer record's `on_end_processors` closure. All OTel-referencing code sits behind a compile-time `Code.ensure_loaded?(:otel_span)` guard so hosts without the optional dep still compile. Activation reuses #175's `attach_tracer(exporter: …)`; an optional `ready?/0` callback turns "OTel absent" into a startup `ArgumentError`.

**Tech Stack:** Elixir, `:opentelemetry` 1.7 / `:opentelemetry_api` 1.5 (optional deps), `:telemetry`, ExUnit. Interop verified against `opentelemetry-erlang` tag `9f0511e`.

**Design doc:** `docs/superpowers/specs/2026-06-09-opentelemetry-exporter-design.md`

---

## Verified interop facts (the load-bearing constants — do not guess these)

- `Trace.Span` fields: `trace_id`/`span_id`/`parent_span_id` are **hex strings** (`parent_span_id` may be `nil`); `kind` is `:internal|:server|:client|nil`; `status` is `:unset|:ok|:error|nil`; `start_time` is **native `system_time`**; `duration_native` is a native monotonic delta; `events` are maps `%{name:, time: <native monotonic>, attributes:}` (the exception event has **no** `:time`); `links` is always `[]` today; `pid`/`node` present.
- OTel `#span{}` record (`opentelemetry/include/otel_span.hrl`, tag `:span`): `trace_id`/`span_id`/`parent_span_id` are **integers** (decode hex with `String.to_integer(hex, 16)`); `start_time`/`end_time` are **native monotonic** (exporter re-adds `:erlang.time_offset()`); `kind` ∈ `:internal|:server|:client`; `status` is a `#status{}`; `attributes`/`events`/`links` are **wrapper records** (build via constructors, never literals); `trace_flags` **must keep the sampled bit (1)** or the processor silently drops the span; `is_recording: false`; `instrumentation_scope` set explicitly.
- Timestamp conversion: our `start_time` is `system_time` = `monotonic_time + time_offset`, so the SDK's monotonic-frame value is `start_time - :erlang.time_offset()`. Event `system_time_native` wants raw monotonic — our `event.time` already is that (no conversion).
- Constructors (all verified): `:opentelemetry.status(:error, msg)` / `:opentelemetry.status(:unset, "")`; `:otel_attributes.new(map, 128, :infinity)` (**does NOT filter — pre-coerce values**); `:otel_events.new(128, 128, :infinity)` then `:otel_events.add(list, acc)` with event maps keyed `system_time_native:`; `:otel_links.new([], 128, 128, :infinity)`; `:opentelemetry.instrumentation_scope("image_pipe", vsn, :undefined)`.
- Injection seam: `:opentelemetry.get_tracer(:image_pipe)` → `{:otel_tracer_default, tracer}` (running) or `{:otel_tracer_noop, []}` (not running). The `#tracer{}` fields are `module, on_start_processors, on_end_processors, …`, so `on_end_processors` is **`elem(tracer, 3)`** — a `fun((span) -> boolean)` that folds every configured processor's `on_end/2`. We read it by position (not via the internal `src/otel_tracer.hrl`) and let the canary test guard the position.
- Test harness: `config :opentelemetry, span_processor: :simple, traces_exporter: :none`, then per-test `:otel_simple_processor.set_exporter(:otel_exporter_pid, self())`; finished spans arrive as `{:span, span_record}` messages.

---

## File structure

- **Modify** `mix.exs` — add `:opentelemetry`/`:opentelemetry_api` as `optional: true` (and to `:test`/`:dev` envs so we compile/test against them).
- **Modify** `config/config.exs` — test-env OTel SDK config (simple processor, no real exporter).
- **Modify** `lib/image_pipe/telemetry/trace/exporter.ex` — add optional `c:ready?/0` callback.
- **Create** `lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex` — the exporter (compile-guarded).
- **Modify** `lib/image_pipe/telemetry.ex` — `attach_tracer/1` `ready?/0` probe; boundary `exports:`.
- **Create** `test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs` — canary, mapping, coercion, gate.
- **Create** `test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs` — real `ImagePipe.call/2` ID-preservation + safety.
- **Create** `docs/cookbook/opentelemetry-jaeger.md` — local Jaeger recipe; add to `mix.exs` docs `extras`/`package`.
- **Modify** `docs/telemetry.md` — `### OpenTelemetry export` subsection.
- **Modify** `CLAUDE.md` — telemetry-guideline carve-out.

---

## Task 1: Optional dependencies + test config

**Files:**
- Modify: `mix.exs:104-142` (deps)
- Modify: `config/config.exs`

- [ ] **Step 1: Add the optional deps.** In `mix.exs`, inside `base = [ … ]`, add after the `{:telemetry, "~> 1.0"},` line:

```elixir
      {:opentelemetry, "~> 1.7", optional: true, only: [:dev, :test]},
      {:opentelemetry_api, "~> 1.5", optional: true, only: [:dev, :test]},
```

Rationale: `optional: true` keeps them off hosts' hard dep list; `only: [:dev, :test]` fetches them for our own compile/test (a host that wants OTLP adds `:opentelemetry` to *their* deps). The exporter module's compile guard (Task 3) handles the prod-build-without-dep case.

- [ ] **Step 2: Add test-env SDK config.** Replace the body of `config/config.exs` with:

```elixir
import Config

# config :image_pipe, ImagePipe, ...

if config_env() == :test do
  # Synchronous simple processor with no real exporter; tests swap in a pid
  # exporter per-test via :otel_simple_processor.set_exporter/2.
  config :opentelemetry,
    span_processor: :simple,
    traces_exporter: :none
end
```

- [ ] **Step 3: Fetch deps.**

Run: `mise exec -- mix deps.get`
Expected: resolves `opentelemetry`, `opentelemetry_api`, `opentelemetry_exporter`? (only the two we named + their transitive `opentelemetry_semantic_conventions`); no errors.

- [ ] **Step 4: Confirm they compile and the app boots in test.**

Run: `mise exec -- mix compile`
Expected: compiles clean (no warnings-as-errors yet; just confirm the deps build).

- [ ] **Step 5: Commit.**

```bash
git add mix.exs mix.lock config/config.exs
git commit -m "build(telemetry): add optional opentelemetry deps + test SDK config"
```

---

## Task 2: `ready?/0` optional callback on the Exporter behaviour

**Files:**
- Modify: `lib/image_pipe/telemetry/trace/exporter.ex`

- [ ] **Step 1: Add the optional callback.** Append before the final `end` of the module (after the `@callback export/1` line):

```elixir
  @doc """
  Optional readiness gate, consulted by `ImagePipe.Telemetry.attach_tracer/1`.

  Return `false` when the exporter cannot run in the current build/runtime (e.g.
  an optional backend dependency is not loaded). `attach_tracer/1` raises
  `ArgumentError` instead of attaching, turning a missing dependency into an
  actionable startup error rather than a per-request crash. Exporters that omit
  this callback are always considered ready.
  """
  @callback ready?() :: boolean()

  @optional_callbacks ready?: 0
```

- [ ] **Step 2: Compile.**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: PASS (LogExporter doesn't implement the optional callback — fine, it's optional).

- [ ] **Step 3: Commit.**

```bash
git add lib/image_pipe/telemetry/trace/exporter.ex
git commit -m "feat(telemetry): add optional Trace.Exporter ready?/0 callback"
```

---

## Task 3: Exporter module + injection canary (verify-first)

This is the keystone. We build the real `export/1` and immediately prove, via a synchronous simple-processor + pid-exporter test, that our exact hex IDs land on a finished `#span{}`.

**Files:**
- Create: `lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex`
- Create: `test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs`

- [ ] **Step 1: Write the failing canary test.** Create `test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs`:

```elixir
defmodule ImagePipe.Telemetry.Trace.OpenTelemetryExporterTest do
  use ExUnit.Case, async: false

  require Record
  # Read finished #span{} records the pid exporter sends us. The header is the
  # SDK's public include/ dir; if its shape changes on an OTel upgrade this
  # extract (and the assertions below) break — that is the intended canary.
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

  test "injects a finished span carrying our exact hex trace_id/span_id/parent" do
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
    assert otel_span(rec, :trace_id) == 0x0123456789ABCDEF0123456789ABCDEF
    assert otel_span(rec, :span_id) == 0x89ABCDEF01234567
    assert otel_span(rec, :parent_span_id) == 0xFEDCBA9876543210
    assert otel_span(rec, :name) == "image_pipe.request"
    assert otel_span(rec, :kind) == :server
  end
end
```

- [ ] **Step 2: Run it to verify it fails.**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs -v`
Expected: FAIL — `OpenTelemetryExporter.export/1` undefined (module not yet created).

- [ ] **Step 3: Implement the exporter.** Create `lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex`:

```elixir
defmodule ImagePipe.Telemetry.Trace.OpenTelemetryExporter do
  @moduledoc """
  Opt-in `ImagePipe.Telemetry.Trace.Exporter` that bridges finished spans into a
  host-running OpenTelemetry SDK, preserving ImagePipe's own trace/span IDs so
  exported spans stitch to the W3C `traceparent` `Trace.ReqStep` already injects.

  Optional dependency: requires the host to add `:opentelemetry` (+ an OTLP
  exporter such as `:opentelemetry_exporter`) to their deps and start the SDK.
  When `:opentelemetry` is not compiled in, this module degrades to a no-op and
  `ready?/0` returns `false` (so `attach_tracer/1` raises an actionable error).

  There is no public OTel API to record a span with a caller-chosen `span_id`, so
  this constructs the SDK-internal `#span{}` record and runs the host's configured
  span processors over it. That couples to internal records; the shape is read by
  field name / guarded position and the integration test acts as an upgrade canary.
  See `docs/superpowers/specs/2026-06-09-opentelemetry-exporter-design.md`.
  """
  @behaviour ImagePipe.Telemetry.Trace.Exporter

  alias ImagePipe.Telemetry.Trace.Span

  # Attribute/event/link limits handed to the OTel constructors.
  @count_limit 128
  @value_length_limit :infinity

  if Code.ensure_loaded?(:otel_span) do
    require Record

    Record.defrecordp(
      :otel_span,
      :span,
      Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
    )

    @doc "Whether the OpenTelemetry SDK dependency is compiled in."
    @spec available?() :: boolean()
    def available?, do: Code.ensure_loaded?(:otel_span)

    @impl true
    @spec ready?() :: boolean()
    def ready?, do: available?()

    @impl true
    @spec export(Span.t()) :: :ok
    def export(%Span{} = span) do
      case :opentelemetry.get_tracer(:image_pipe) do
        {:otel_tracer_default, tracer} ->
          on_end = elem(tracer, 3)
          _ = on_end.(build_record(span))
          :ok

        # Noop tracer: dep present but SDK not started / noop provider. Drop.
        _ ->
          :ok
      end
    end

    defp build_record(%Span{} = span) do
      offset = :erlang.time_offset()
      start_native = (span.start_time || 0) - offset
      end_native = start_native + (span.duration_native || 0)

      otel_span(
        trace_id: decode_id(span.trace_id),
        span_id: decode_id(span.span_id),
        parent_span_id: decode_parent(span.parent_span_id),
        name: span.name,
        kind: kind(span.kind),
        start_time: start_native,
        end_time: end_native,
        attributes: attributes(span),
        events: events(span, end_native),
        links: :otel_links.new([], @count_limit, @count_limit, @value_length_limit),
        status: status(span),
        trace_flags: span.trace_flags,
        is_recording: false,
        instrumentation_scope: scope()
      )
    end

    defp decode_id(hex) when is_binary(hex), do: String.to_integer(hex, 16)
    defp decode_parent(nil), do: :undefined
    defp decode_parent(hex) when is_binary(hex), do: String.to_integer(hex, 16)

    defp kind(k) when k in [:internal, :server, :client], do: k
    defp kind(_), do: :internal

    defp status(%Span{status: :error} = span),
      do: :opentelemetry.status(:error, span.status_message || "")

    defp status(%Span{status: :ok}), do: :opentelemetry.status(:ok, "")
    defp status(_), do: :opentelemetry.status(:unset, "")

    defp scope do
      vsn = to_string(Application.spec(:image_pipe, :vsn) || "0.0.0")
      :opentelemetry.instrumentation_scope("image_pipe", vsn, :undefined)
    end

    defp attributes(%Span{} = span) do
      span.attributes
      |> coerce_map()
      |> put_present("image_pipe.pid", span.pid, &inspect/1)
      |> put_present("image_pipe.node", span.node, &Atom.to_string/1)
      |> :otel_attributes.new(@count_limit, @value_length_limit)
    end

    defp events(%Span{events: events}, fallback_time) do
      maps =
        Enum.map(events, fn ev ->
          %{
            system_time_native: Map.get(ev, :time) || fallback_time,
            name: ev[:name],
            attributes: coerce_map(Map.get(ev, :attributes, %{}))
          }
        end)

      :otel_events.add(maps, :otel_events.new(@count_limit, @count_limit, @value_length_limit))
    end

    defp put_present(map, _key, nil, _fun), do: map
    defp put_present(map, key, value, fun), do: Map.put(map, key, fun.(value))

    # OTel attribute values must be primitives; :otel_attributes.new/3 does NOT
    # filter, so coerce here. Sensitivity is already handled upstream by
    # Capture.safe_attrs/1 — this is a type concern only.
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
  else
    @doc "OpenTelemetry SDK not compiled in; this exporter is a no-op."
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

- [ ] **Step 4: Run the canary to verify it passes.**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs -v`
Expected: PASS — the received `#span{}` carries our integer-decoded IDs, name, and kind.

- [ ] **Step 5: Compile clean.**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs
git commit -m "feat(telemetry): OpenTelemetry exporter — inject #span{} preserving our ids"
```

---

## Task 4: Mapping fidelity — timestamps, status, attribute coercion

Extend the unit test to lock the non-ID mapping: native-time/duration, error status + message, and coercion of an opaque struct / pid / node / nil.

**Files:**
- Modify: `test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs`

- [ ] **Step 1: Add the failing mapping tests.** Add inside the test module (after the canary test). Note the attributes wrapper record is `{:attributes, count_limit, value_length_limit, dropped, map}`, so the raw map is `elem(_, 4)`:

```elixir
  test "maps duration to an exact on-wire span duration" do
    start = System.system_time()

    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      name: "image_pipe.transform.execute",
      kind: :internal,
      start_time: start,
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
    # #status{} runtime tuple is {:status, code, message}
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
      # :params stands in for an opaque operation struct; 1..3 is any struct.
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
```

- [ ] **Step 2: Run.**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs -v`
Expected: PASS (the Task 3 implementation already satisfies these — these tests *lock* the behavior; if any fails, fix the mapping in `open_telemetry_exporter.ex`).

- [ ] **Step 3: Commit.**

```bash
git add test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs
git commit -m "test(telemetry): lock OTel mapping — duration, status, attribute coercion"
```

---

## Task 5: End-to-end ID preservation through a real request

Prove the whole bridge over a real `ImagePipe.call/2`: one trace, correct parent nesting, our IDs, and the safety invariant (no signed URL leaks into exported attributes).

**Files:**
- Create: `test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs`

- [ ] **Step 1: Write the failing integration test.** Create the file. Adapt the request setup to mirror the existing tracer wire-test (look at `test/image_pipe/telemetry/` for the #175 `TestExporter`/request helpers and reuse the same fixture/source-stub pattern; the skeleton below is the OTel-specific shape):

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
  alias ImagePipe.Telemetry.Trace.OpenTelemetryExporter

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    Telemetry.attach_tracer(exporter: OpenTelemetryExporter, finch_spans: false)

    on_exit(fn ->
      Telemetry.detach_tracer()
      :otel_simple_processor.set_exporter(:none, [])
    end)

    :ok
  end

  test "a real request exports one trace with correct parent nesting and our ids" do
    # TODO(executor): issue a real ImagePipe.call/2 the same way the #175 tracer
    # wire test does (reuse its endpoint opts + stubbed source). Then drain spans:
    spans = drain_spans()

    # All spans share one trace_id.
    trace_ids = spans |> Enum.map(&otel_span(&1, :trace_id)) |> Enum.uniq()
    assert length(trace_ids) == 1

    # The request (root) span has no parent; at least one child references a span
    # that exists in the set (nesting is internally consistent).
    by_id = Map.new(spans, &{otel_span(&1, :span_id), &1})
    root = Enum.find(spans, &(otel_span(&1, :parent_span_id) == :undefined))
    assert root, "expected a root span"
    assert otel_span(root, :name) == "image_pipe.request"

    children = Enum.reject(spans, &(otel_span(&1, :parent_span_id) == :undefined))
    assert children != []

    Enum.each(children, fn s ->
      assert Map.has_key?(by_id, otel_span(s, :parent_span_id)),
             "child #{otel_span(s, :name)} points at a parent not in the trace"
    end)
  end

  test "no signed source URL leaks into any exported span attribute" do
    _spans = drain_spans_after_signed_url_request()
    # Assert the secret substring appears in NO exported attribute value.
    # (Capture.safe_attrs already strips URLs; this re-asserts at the OTel
    # boundary, where coercion inspect()s opaque terms.)
    refute Enum.any?(collected_attribute_values(), &String.contains?(&1, "X-Amz-Signature"))
  end

  # --- helpers (executor fills in using the #175 wire-test fixtures) ---
  defp drain_spans(acc \\ []) do
    receive do
      {:span, rec} -> drain_spans([rec | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  defp drain_spans_after_signed_url_request, do: drain_spans()
  defp collected_attribute_values, do: []
end
```

> **Executor note:** the two `TODO`/stub helpers must be completed against the real #175 tracer wire test (`grep -rl "attach_tracer\|TestExporter" test/`). Issue the same request that test issues; for the safety test, route through a source whose URL carries an `X-Amz-Signature=` query param and collect every exported attribute value (`elem(otel_span(rec, :attributes), 4) |> Map.values() |> Enum.filter(&is_binary/1)`). Do **not** ship this task with the stubs returning `[]` — that would make the safety assertion vacuously pass.

- [ ] **Step 2: Run; expect failure, then complete the stubs.**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs -v`
Expected: initially FAIL/empty; iterate until both tests exercise a real request and pass.

- [ ] **Step 3: Commit.**

```bash
git add test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs
git commit -m "test(telemetry): e2e OTel export — id preservation, nesting, url safety"
```

---

## Task 6: `attach_tracer/1` readiness probe + gate test

**Files:**
- Modify: `lib/image_pipe/telemetry.ex:135-138`
- Modify: `test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs`

- [ ] **Step 1: Write the failing gate test.** Add to `open_telemetry_exporter_test.exs`. Use a tiny inline not-ready exporter so the test doesn't depend on OTel being absent (it isn't, in our env):

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

- [ ] **Step 2: Run to verify it fails.**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs -v`
Expected: FAIL — currently `attach_tracer` would attach NotReadyExporter without raising.

- [ ] **Step 3: Add the probe.** In `lib/image_pipe/telemetry.ex`, immediately after the existing `unless Code.ensure_loaded?(exporter) … end` block (line 135-138), insert:

```elixir
    if function_exported?(exporter, :ready?, 0) and not exporter.ready?() do
      raise ArgumentError,
            "exporter #{inspect(exporter)} is not ready: ready?/0 returned false " <>
              "(for OpenTelemetryExporter, add :opentelemetry to your host deps)"
    end
```

- [ ] **Step 4: Run to verify it passes.**

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add lib/image_pipe/telemetry.ex test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs
git commit -m "feat(telemetry): attach_tracer raises on a not-ready exporter"
```

---

## Task 7: Boundary export, docs, cookbook, guideline carve-out

**Files:**
- Modify: `lib/image_pipe/telemetry.ex:13`
- Create: `docs/cookbook/opentelemetry-jaeger.md`
- Modify: `docs/telemetry.md`
- Modify: `CLAUDE.md`
- Modify: `mix.exs` (docs `extras` + `package` files)

- [ ] **Step 1: Export the module from the telemetry boundary.** In `lib/image_pipe/telemetry.ex`, line 13, add `Trace.OpenTelemetryExporter` to the `exports:` list:

```elixir
    exports: [
      Trace,
      Trace.Stack,
      Trace.Context,
      Trace.Span,
      Trace.Exporter,
      Trace.ReqStep,
      Trace.OpenTelemetryExporter
    ]
```

> Note: the telemetry boundary keeps `deps: []`. The exporter calls only the external `:opentelemetry`/`:otel_*` apps (outside Boundary's governance) and `Trace.Span` (same boundary) — it never references `ImagePipe.Transform.*`, which Boundary's `deps: []` enforces at compile time. No separate architecture-test assertion is needed (the exporter doesn't subscribe to telemetry events, so the #175 capture source-scan doesn't apply to it).

- [ ] **Step 2: Create the Jaeger cookbook.** Create `docs/cookbook/opentelemetry-jaeger.md`:

```markdown
# Cookbook: OpenTelemetry traces to Jaeger (local)

ImagePipe emits `:telemetry` spans and ships an opt-in exporter that bridges them
into your OpenTelemetry SDK, preserving ImagePipe's own trace/span IDs. This recipe
sends traces to a local Jaeger all-in-one.

## 1. Run Jaeger

```yaml
# docker-compose.yml
services:
  jaeger:
    image: jaegertracing/all-in-one:1.60
    ports:
      - "16686:16686"   # UI
      - "4317:4317"     # OTLP gRPC
      - "4318:4318"     # OTLP HTTP
```

`docker compose up -d`, then open http://localhost:16686.

## 2. Add the OpenTelemetry deps (host side)

```elixir
# mix.exs
{:opentelemetry, "~> 1.7"},
{:opentelemetry_exporter, "~> 1.8"},
```

`:opentelemetry` is an *optional* dependency of ImagePipe — you add it; ImagePipe
ships only the bridge adapter.

## 3. Point the SDK at Jaeger

```elixir
# config/runtime.exs (or config/dev.exs)
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "http://localhost:4318"
```

Set `OTEL_RESOURCE_ATTRIBUTES=service.name=my-image-host` (or the equivalent
`:opentelemetry, resource:` config) — the resource is yours; ImagePipe sets only the
`image_pipe` instrumentation scope.

## 4. Activate the exporter at startup

```elixir
ImagePipe.Telemetry.attach_tracer(
  exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
  extract_inbound: true   # continue an upstream W3C traceparent
)
```

If `:opentelemetry` isn't in your deps, this raises a clear `ArgumentError` at
startup rather than failing per request. Issue a request and find the
`image_pipe.request` trace in Jaeger.
```

- [ ] **Step 3: Add the `### OpenTelemetry export` subsection to `docs/telemetry.md`.** Under the existing `## Tracing (opt-in)` section (find it: `grep -n "Tracing (opt-in)\|attach_tracer" docs/telemetry.md`), add:

```markdown
### OpenTelemetry export

ImagePipe ships an opt-in exporter, `ImagePipe.Telemetry.Trace.OpenTelemetryExporter`,
that bridges captured spans into a host-running OpenTelemetry SDK. It is an
**optional dependency**: ImagePipe declares `:opentelemetry` as `optional: true` and
detects it at runtime — the *host* adds the dependency and configures the OTLP
backend. With the dep absent the exporter is a no-op and `attach_tracer/1` raises.

```elixir
# host deps: {:opentelemetry, "~> 1.7"}, {:opentelemetry_exporter, "~> 1.8"}
ImagePipe.Telemetry.attach_tracer(
  exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
  extract_inbound: true
)
```

**ID ownership.** ImagePipe owns the trace/span IDs (it already injects W3C
`traceparent` outbound), and the exporter feeds them to the SDK verbatim — so a
trace started upstream and continued downstream stays one coherent trace. Achieving
this requires recording spans through the SDK's internal span path, so the bridge
depends on the OpenTelemetry **SDK** (`:opentelemetry`), not just the lightweight
`:opentelemetry_api`. The host owns the **Resource** (`service.name`, …); ImagePipe
sets only the `image_pipe` instrumentation scope.

The host must have started the OpenTelemetry SDK with a span processor + exporter
(e.g. `:otlp`). If no real provider is running, exported spans are dropped by the SDK.

See the local Jaeger recipe in `docs/cookbook/opentelemetry-jaeger.md`.
```

Also update any line in `docs/telemetry.md` that states ImagePipe "doesn't depend on
OpenTelemetry" to "doesn't *hard*-depend on OpenTelemetry; ships an optional, opt-in
OTel bridge" (`grep -n "OpenTelemetry" docs/telemetry.md`).

- [ ] **Step 4: Amend the CLAUDE.md telemetry guideline.** In `CLAUDE.md`, find the line "Keep third-party backend integrations out of the library: hosts attach AppSignal, OpenTelemetry, and metrics handlers themselves." Append to that bullet:

```
 The one exception is an opt-in, optional-dependency bridge *exporter* (e.g. `ImagePipe.Telemetry.Trace.OpenTelemetryExporter`) that ships adapter code only, declares the backend as `optional: true`, is never attached automatically, and pulls in no dependency on its own — the host still provides the SDK and configures the backend. This preserves "no hard dependency" while offering a battery.
```

- [ ] **Step 5: Add the cookbook to docs/package lists.** In `mix.exs`, add `"docs/cookbook/opentelemetry-jaeger.md"` to the `docs: [extras: [...]]` list (after `"docs/telemetry.md"`) and to the `package: [files: [...]]` list.

- [ ] **Step 6: Verify docs build and boundary holds.**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: PASS (boundary export resolves; no new boundary violations).

- [ ] **Step 7: Commit.**

```bash
git add lib/image_pipe/telemetry.ex docs/cookbook/opentelemetry-jaeger.md docs/telemetry.md CLAUDE.md mix.exs
git commit -m "docs(telemetry): OTel export docs, Jaeger cookbook, boundary export, guideline carve-out"
```

---

## Task 8: Full gate

- [ ] **Step 1: Run the focused telemetry tests.**

Run: `mise exec -- mix test test/image_pipe/telemetry/`
Expected: PASS.

- [ ] **Step 2: Run the full precommit gate.**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all PASS.

- [ ] **Step 3: Final commit (if formatting/credo required touch-ups).**

```bash
git add -A
git commit -m "chore(telemetry): precommit clean for OTel exporter"
```

---

## Self-review notes (carried into execution)

- **Compile-time optionality** (Task 1 `only: [:dev,:test]` + Task 3 `Code.ensure_loaded?(:otel_span)` guard) is what keeps hosts-without-OTel compiling. If a step ever moves OTel code outside the `if` branch, the prod build breaks — keep all `:otel_*`/`Record.extract` references inside it.
- **Canary discipline** (Tasks 3/5): the `Record.extract(:span, from_lib:)` + `elem(tracer, 3)` are the only internal-shape couplings. Both are exercised by tests, so an OTel upgrade that changes them fails CI rather than silently mis-exporting. Keep `:opentelemetry` pinned `~> 1.7`.
- **Safety test must not be vacuous** (Task 5): the signed-URL helpers must drive a real request; a stub returning `[]` makes `refute Enum.any?(...)` pass for the wrong reason.
- **Type consistency:** `available?/0`, `ready?/0`, `export/1` are defined in both `if`/`else` branches with identical signatures; `ready?/0` is the `@optional_callbacks` member added in Task 2.
