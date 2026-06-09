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

- **Modify** `mix.exs` — add `:opentelemetry`/`:opentelemetry_api` as `optional: true` (no `only:`).
- **Modify** `config/config.exs` — test-env OTel SDK config (simple processor, no real exporter).
- **Modify** `lib/image_pipe/telemetry/trace/exporter.ex` — add optional `c:ready?/0` callback.
- **Create** `lib/image_pipe/telemetry/trace/open_telemetry/span_record.ex` — the **quarantined FFI** (the only module touching OTel internals; compile-guarded).
- **Create** `lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex` — the clean behaviour impl + `@tested_range` version gate; delegates record-building to `SpanRecord`.
- **Modify** `lib/image_pipe/telemetry.ex` — `attach_tracer/1` `ready?/0` probe; boundary `exports:` (export `OpenTelemetryExporter` only, not `SpanRecord`).
- **Create** `test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs` — canary, structural-contract, mapping, coercion, noop, gate, version-range.
- **Create** `test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs` — real `ImagePipe.call/2` ID-preservation + safety + **cross-consumer correlation** (LogExporter + OTel share `{trace_id, span_id}`).
- **Create** `docs/cookbook/opentelemetry-jaeger.md` — local Jaeger recipe; add to `mix.exs` docs `extras`/`package`.
- **Create** `.github/workflows/otel-compat.yml` + Renovate/Dependabot config — currency tooling (§10 "Staying current").
- **Modify** `docs/telemetry.md` — `### OpenTelemetry export` subsection.
- **Modify** `CLAUDE.md` — telemetry-guideline carve-out.

---

## Task 1: Optional dependencies + test config

**Files:**
- Modify: `mix.exs:104-142` (deps)
- Modify: `config/config.exs`

- [ ] **Step 1: Add the optional deps.** In `mix.exs`, inside `base = [ … ]`, add after the `{:telemetry, "~> 1.0"},` line:

```elixir
      # OpenTelemetry is an OPTIONAL bridge dependency. Use `optional: true` and
      # DO NOT add `only: [:dev, :test]`. The `optional: true` edge is what makes
      # Mix compile a host-provided `:opentelemetry` BEFORE image_pipe, so the
      # `Code.ensure_loaded?(:otel_span)` compile guard in OpenTelemetryExporter
      # resolves `true` in the host's build and the exporter actually works. Adding
      # `only:` would strip that edge for downstream hosts → the guard would pick the
      # no-op branch → the exporter would silently do nothing even when the host has
      # OTel. (Fetched for our own builds because optional deps are fetched for the
      # defining project; never forced onto hosts.)
      {:opentelemetry, "~> 1.7", optional: true},
      {:opentelemetry_api, "~> 1.5", optional: true},
```

Rationale: `optional: true` (no `only:`) declares a real-but-optional dependency edge. For a downstream host: nothing is pulled in unless the host adds `:opentelemetry` themselves; when they do, the edge orders its compilation before image_pipe so the Task 3 guard sees it. For us: the deps are fetched/compiled in all our envs so the exporter compiles and tests run. A host build *without* OTel sees `:otel_span` unloadable → the guard's no-op `else` branch (Task 3) — the correct degradation.

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

- [ ] **Step 5: Record the host-simulation caveat (CRITICAL — no automated test covers this).** Our own suite *always* has `:opentelemetry` present, so it can never catch a regression where the exporter becomes a no-op for real hosts (e.g. someone re-adds `only:` to the deps). There is no cheap in-repo automated guard for "image_pipe-as-a-dependency + host adds OTel." Document the manual smoke-check in the PR description and run it once before release:

> In a throwaway app that depends on `image_pipe` (path or git) **and** adds `{:opentelemetry, "~> 1.7"}`, assert `ImagePipe.Telemetry.Trace.OpenTelemetryExporter.available?() == true`. If it returns `false`, the optional-dep edge is broken (check for a stray `only:` on the deps).

The loud mix.exs comment from Step 1 is the primary defense; this smoke-check is the backstop.

- [ ] **Step 6: Commit.**

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
- Create: `lib/image_pipe/telemetry/trace/open_telemetry/span_record.ex` (quarantined FFI)
- Create: `lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex` (clean impl + gate)
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

- [ ] **Step 3: Implement the FFI module and the clean exporter.** Create the quarantined `lib/image_pipe/telemetry/trace/open_telemetry/span_record.ex` (the only module touching SDK internals) and the thin `lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex` (behaviour impl + `@tested_range` gate, delegating to `SpanRecord`):

```elixir
# ---- FFI quarantine module: the ONLY place that touches OTel SDK internals ----
defmodule ImagePipe.Telemetry.Trace.OpenTelemetry.SpanRecord do
  @moduledoc """
  UNSUPPORTED OpenTelemetry SDK bridge — the single quarantined FFI boundary.

  This is the ONLY module in the codebase that touches opentelemetry-erlang
  internals: `Record.extract(:span, …)`, the `#span{}`/`#status{}`/`#event{}` shapes,
  the `elem(tracer, 3)` `on_end_processors` closure, the native-time conversion, and
  the `:otel_attributes`/`:otel_events`/`:otel_links` constructors. There is no public
  OTel API to record a span with a caller-chosen `span_id`, so we construct the
  internal record and run the host's processors over it.

  Intentionally version-pinned. May break on an OpenTelemetry upgrade — the
  structural-contract + integration tests are the canary, and
  `OpenTelemetryExporter`'s `@tested_range` gate refuses untested versions at startup.
  Everything outside this module speaks `%Trace.Span{}`.
  """
  alias ImagePipe.Telemetry.Trace.Span

  @count_limit 128
  @value_length_limit :infinity

  if Code.ensure_loaded?(:otel_span) do
    require Record

    Record.defrecordp(
      :otel_span,
      :span,
      Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
    )

    @spec available?() :: boolean()
    def available?, do: Code.ensure_loaded?(:otel_span)

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

    # OTel attribute values must be primitives (binary/number/boolean/atom or a
    # homogeneous list). A raw operation struct, tuple, or map is not a valid
    # value — depending on the SDK path it is either dropped or breaks the OTLP
    # encoder — so we coerce every non-primitive to a string here, guaranteeing
    # only primitives reach :otel_attributes.new/3. Sensitivity is already handled
    # upstream by Capture.safe_attrs/1 — this is a type concern only.
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
    @spec available?() :: boolean()
    def available?, do: false

    @spec export(Span.t()) :: :ok
    def export(%Span{}), do: :ok
  end
end
```

```elixir
# ---- Clean exporter: behaviour impl + activation gate. Knows no internals. ----
defmodule ImagePipe.Telemetry.Trace.OpenTelemetryExporter do
  @moduledoc """
  Opt-in `ImagePipe.Telemetry.Trace.Exporter` that bridges finished `%Trace.Span{}`
  structs into a host-running OpenTelemetry SDK, preserving ImagePipe's own
  trace/span IDs so every observer of a logical operation — logs, metrics, custom
  exporters, and OTel — shares one `{trace_id, span_id}` join key.

  Optional dependency: the host adds `:opentelemetry` (+ an OTLP exporter) and starts
  the SDK. When OTel is absent or its version is outside ImagePipe's tested range,
  `ready?/0` returns `false` so `attach_tracer/1` raises an actionable startup error
  rather than emitting (possibly malformed) spans.

  All SDK-internals coupling lives in `ImagePipe.Telemetry.Trace.OpenTelemetry.SpanRecord`.
  See `docs/superpowers/specs/2026-06-09-opentelemetry-exporter-design.md`.
  """
  @behaviour ImagePipe.Telemetry.Trace.Exporter

  require Logger
  alias ImagePipe.Telemetry.Trace.OpenTelemetry.SpanRecord
  alias ImagePipe.Telemetry.Trace.Span

  # The OTel versions whose record/closure shapes we have canary-tested. May be
  # narrower than the mix.exs dep constraint: a host can RESOLVE a newer 1.x, but we
  # refuse to ACTIVATE against it rather than risk malformed spans.
  @tested_range "~> 1.7"

  @doc "Whether the OpenTelemetry SDK dependency is compiled in."
  @spec available?() :: boolean()
  def available?, do: SpanRecord.available?()

  # NOTE: side-effecting — logs the specific disable reason. Called once, at
  # attach_tracer time (host startup); never in a hot path. Don't call speculatively.
  @impl true
  @spec ready?() :: boolean()
  def ready? do
    cond do
      not available?() ->
        Logger.warning(
          "OpenTelemetryExporter disabled: :opentelemetry is not loaded; add it to your host deps."
        )

        false

      not version_supported?(otel_vsn()) ->
        Logger.warning(
          "OpenTelemetryExporter disabled: OpenTelemetry #{otel_vsn()} is outside the tested " <>
            "range #{@tested_range}; refusing to emit possibly-malformed spans."
        )

        false

      true ->
        true
    end
  end

  @impl true
  @spec export(Span.t()) :: :ok
  def export(%Span{} = span), do: SpanRecord.export(span)

  @doc """
  Whether an OTel version string falls in ImagePipe's canary-tested range.

  Returns `false` (never raises) for `nil`, a malformed/non-SemVer version, or a
  pre-release (e.g. `1.7.0-rc.1`) — all "not blessed" → loud-disable, not a crash.
  `Version.match?/2` would otherwise raise `Version.InvalidVersionError` on a 2-part
  version, which would escape `attach_tracer` instead of degrading cleanly.
  """
  @spec version_supported?(String.t() | nil) :: boolean()
  def version_supported?(nil), do: false

  def version_supported?(vsn) when is_binary(vsn) do
    case Version.parse(vsn) do
      {:ok, _parsed} -> Version.match?(vsn, @tested_range)
      :error -> false
    end
  end

  defp otel_vsn do
    case Application.spec(:opentelemetry, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
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
git add lib/image_pipe/telemetry/trace/open_telemetry/span_record.ex lib/image_pipe/telemetry/trace/open_telemetry_exporter.ex test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs
git commit -m "feat(telemetry): OpenTelemetry exporter — inject #span{} preserving our ids"
```

- [ ] **Step 7: Add the structural-contract tests (FFI tripwires).** Append to `open_telemetry_exporter_test.exs`. These pin each internal assumption so an OTel upgrade fails with a *localized* message:

```elixir
  describe "structural contract (FFI tripwires — fail loudly on an OTel shape change)" do
    test "tracer exposes the on_end closure at tuple position 3" do
      assert {:otel_tracer_default, tracer} = :opentelemetry.get_tracer(:image_pipe)
      assert is_function(elem(tracer, 3), 1)
    end

    test "status/2 returns the {:status, code, message} shape we map onto" do
      assert {:status, :error, "boom"} = :opentelemetry.status(:error, "boom")
      assert {:status, :unset, _} = :opentelemetry.status(:unset, "")
    end

    test "instrumentation_scope/3 returns the record shape we build" do
      assert {:instrumentation_scope, "image_pipe", "9.9.9", :undefined} =
               :opentelemetry.instrumentation_scope("image_pipe", "9.9.9", :undefined)
    end

    test "the :span record still exposes every field build_record/1 sets" do
      fields =
        Keyword.keys(Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

      for f <- [
            :trace_id, :span_id, :parent_span_id, :name, :kind, :start_time, :end_time,
            :attributes, :events, :links, :status, :trace_flags, :is_recording,
            :instrumentation_scope
          ] do
        assert f in fields, "OTel #span{} dropped field #{inspect(f)} — SpanRecord must adapt"
      end
    end
  end
```

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs -v`
Expected: PASS against the pinned OTel; if one fails after an upgrade, its message names exactly what moved.

- [ ] **Step 8: Add the cross-consumer correlation test (the product requirement).** Append. This proves logs and OTel join on `{trace_id, span_id}` — the whole reason we preserve ids:

```elixir
  test "LogExporter and OTel export of one span carry the SAME {trace_id, span_id}" do
    import ExUnit.CaptureLog
    alias ImagePipe.Telemetry.Trace.LogExporter

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

    # LogExporter prints our hex ids; OTel carries the integer decode of the same ids.
    assert log =~ "trace=#{span.trace_id}"
    assert log =~ "span=#{span.span_id}"
    assert String.to_integer(span.trace_id, 16) == otel_span(rec, :trace_id)
    assert String.to_integer(span.span_id, 16) == otel_span(rec, :span_id)
  end
```

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs -v`
Expected: PASS — the log line's ids and the OTel span's ids are the same logical pair.

- [ ] **Step 9: Commit.**

```bash
git add test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs
git commit -m "test(telemetry): structural-contract tripwires + cross-consumer id correlation"
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

  test "an unsampled span (trace_flags: 0) is dropped by the processor" do
    # Pins the load-bearing 'verified interop fact' that the simple/batch
    # processor drops spans without the sampled bit — i.e. we MUST forward
    # trace_flags verbatim and never default it to 0.
    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      name: "image_pipe.request",
      kind: :server,
      start_time: System.system_time(),
      duration_native: 1,
      status: :ok,
      trace_flags: 0
    }

    assert :ok = OpenTelemetryExporter.export(span)
    refute_receive {:span, _}, 100
  end

  test "export/1 no-ops on the noop tracer (SDK not running) and never raises" do
    # Exercises the {:otel_tracer_noop, []} branch by stopping the SDK app so
    # :opentelemetry.get_tracer/1 returns the noop tuple. Restart it afterwards.
    Application.stop(:opentelemetry)

    on_exit(fn ->
      {:ok, _} = Application.ensure_all_started(:opentelemetry)
    end)

    assert {:otel_tracer_noop, []} = :opentelemetry.get_tracer(:image_pipe)

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

> **Executor note:** the noop test stops `:opentelemetry` globally; it is `async: false` (the whole module is), and the `on_exit` restart restores it for subsequent modules. Keep this test last in the file so an accidental ordering issue surfaces locally. The compile-`else` branch (dep entirely absent) is genuinely untestable in our env where the dep is always present — that is acceptable and intentionally uncovered; do not contrive a test for it.

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
    # This re-asserts the URL-secret property at the OTel boundary specifically:
    # coercion inspect()s opaque terms, so its distinct value is "coercion does not
    # re-leak a URL embedded in some struct" — the upstream strip is Capture's job
    # (tested in attr_safety_test.exs). Drive a real request whose source URL
    # carries a signature, then scan every exported string attribute value.
    values = collected_attribute_values_after_signed_url_request()

    # Non-vacuity guard: if the request/drain isn't wired, `values` is empty and
    # the refute below would pass for the wrong reason. Fail loudly instead.
    assert values != [], "no attribute values collected — request/drain not wired"

    refute Enum.any?(values, &String.contains?(&1, "X-Amz-Signature"))
  end

  # --- helpers (executor fills in using the #175 wire-test fixtures) ---
  defp drain_spans(acc \\ []) do
    receive do
      {:span, rec} -> drain_spans([rec | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  # MUST drive a real ImagePipe.call/2 whose source URL literally contains
  # "X-Amz-Signature=" (so the secret has a path to leak), then return EVERY
  # string-valued attribute across ALL exported spans:
  #   drain_spans()
  #   |> Enum.flat_map(fn rec -> elem(otel_span(rec, :attributes), 4) |> Map.values() end)
  #   |> Enum.filter(&is_binary/1)
  # Returning [] (the un-wired stub) is forbidden — the non-vacuity assert above
  # exists precisely to reject that.
  defp collected_attribute_values_after_signed_url_request do
    raise "executor: wire a signed-URL request + collect string attribute values"
  end
end
```

> **Executor note:** complete `collected_attribute_values_after_signed_url_request/0` and the `drain_spans` request setup against the real #175 tracer wire test (`grep -rl "attach_tracer\|TestExporter" test/` → likely `test/image_pipe/telemetry/trace/cross_process_test.exs` + `test/support/trace_test_exporter.ex`). The helper is left as a `raise` (not a `[]` stub) so the task **cannot** be committed green while vacuous — the test will error until it is genuinely wired.

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
- Modify: `test/image_pipe/telemetry/trace/attach_test.exs` (the existing #175 attach-tracer raise tests — this is a generic `Exporter`-contract test, not OTel-specific, so it lives with its peers; confirm the path with `grep -rl "attach_tracer" test/`)

- [ ] **Step 1: Write the failing gate test.** Add to `attach_test.exs`. Use a tiny inline not-ready exporter so the test doesn't depend on OTel being absent (it isn't, in our env) and stays decoupled from the OTel record/processor setup:

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

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/attach_test.exs -v`
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

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/attach_test.exs -v`
Expected: PASS.

- [ ] **Step 5: Add the version-range gate test.** Append to `open_telemetry_exporter_test.exs`. We test the pure `version_supported?/1` seam directly (we can't fake the running app's OTel version), which is what `ready?/0` consults:

```elixir
  describe "version gate" do
    test "version_supported?/1 accepts the tested range and rejects outside it" do
      # @tested_range is "~> 1.7" → >= 1.7.0 and < 2.0.0, release versions only.
      assert OpenTelemetryExporter.version_supported?("1.7.0")
      assert OpenTelemetryExporter.version_supported?("1.7.3")
      assert OpenTelemetryExporter.version_supported?("1.9.0")  # upper edge: any 1.x ≥ 1.7
      refute OpenTelemetryExporter.version_supported?("1.6.9")
      refute OpenTelemetryExporter.version_supported?("2.0.0")  # major break: not blessed
      refute OpenTelemetryExporter.version_supported?(nil)
    end

    test "version_supported?/1 loud-disables (never raises) on pre-release / malformed" do
      # A pre-release is "not blessed" → false (not a crash). OTel ships RCs.
      refute OpenTelemetryExporter.version_supported?("1.7.0-rc.1")
      # A 2-part / non-SemVer string would make Version.match?/2 RAISE; we return false.
      refute OpenTelemetryExporter.version_supported?("1.7")
      refute OpenTelemetryExporter.version_supported?("garbage")
    end

    test "ready?/0 is true in this env (OTel present and in range)" do
      assert OpenTelemetryExporter.ready?()
    end
  end
```

Run: `mise exec -- mix test test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs -v`
Expected: PASS. (An untested-version host hits `version_supported?/1 == false` → `ready?/0 == false` → `attach_tracer` raises the §6 version message.)

- [ ] **Step 6: Commit.**

```bash
git add lib/image_pipe/telemetry.ex test/image_pipe/telemetry/trace/attach_test.exs test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs
git commit -m "feat(telemetry): attach_tracer raises on not-ready/untested-version exporter"
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

## Task 8: Currency tooling (stay current with OpenTelemetry)

The runtime `@tested_range` gate (Task 3) is the defensive layer. This task adds the
reactive (bump PRs) and proactive (scheduled latest-OTel CI) layers so an upstream
shape change is caught before a host hits it. See design §10 "Staying current".

**Files:**
- Create: `.github/dependabot.yml`
- Create: `.github/workflows/otel-compat.yml`

- [ ] **Step 1: Add Dependabot for the OTel deps (reactive).** Create `.github/dependabot.yml` (Dependabot natively supports the `mix` ecosystem; scoped to the two deps so it doesn't churn the rest):

```yaml
version: 2
updates:
  - package-ecosystem: "mix"
    directory: "/"
    schedule:
      interval: "weekly"
    allow:
      - dependency-name: "opentelemetry"
      - dependency-name: "opentelemetry_api"
    commit-message:
      prefix: "build(deps)"
```

A bump PR runs the normal Elixir CI; the structural-contract + correlation tests are the gate. Green → widen `@tested_range` (and the `mix.exs` constraint if needed) in the same PR; red → adapt `SpanRecord`, then bless.

- [ ] **Step 2: Add the scheduled latest-OTel job (proactive).** Create `.github/workflows/otel-compat.yml`. Reuse the **same pinned action SHAs** as `.github/workflows/elixir.yml` (copy the `actions/checkout` and `jdx/mise-action` `uses:` lines verbatim — do not invent SHAs):

```yaml
name: OTel compatibility

on:
  schedule:
    - cron: "0 6 * * 1" # weekly, Monday 06:00 UTC
  workflow_dispatch:

permissions:
  contents: read

jobs:
  otel-latest:
    name: Bridge vs latest OpenTelemetry
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2
      - uses: jdx/mise-action@1648a7812b9aeae629881980618f079932869151 # v4.0.1
        with:
          mise_toml: |
            [tools]
            erlang = "27"
            elixir = "1.18.4-otp-27"
      - run: mise exec -- mix local.hex --force
      - run: mise exec -- mix local.rebar --force
      - name: Loosen the OTel constraint so the resolver can reach the TRUE latest
        # CRITICAL: mix.exs pins `~> 1.7`, which caps `mix deps.*` at < 2.0.0 — so
        # without this the job is blind to the breaking-MAJOR it exists to catch
        # (Dependabot is capped the same way; this job is the only major-aware tripwire).
        # The checkout is ephemeral, so we rewrite the requirement in-job; never committed.
        # Keep these literals in sync with Task 1's deps lines.
        run: |
          mise exec -- elixir -e '
            f = "mix.exs"
            s = File.read!(f)
            s = String.replace(s, ~s({:opentelemetry, "~> 1.7", optional: true}), ~s({:opentelemetry, ">= 0.0.0", optional: true}))
            s = String.replace(s, ~s({:opentelemetry_api, "~> 1.5", optional: true}), ~s({:opentelemetry_api, ">= 0.0.0", optional: true}))
            File.write!(f, s)'
      - name: Guard — fail if the loosen did not apply (literal drift)
        # If Task 1's dep literals ever change, the rewrite above silently no-ops and
        # the job rots back to the capped behavior. Catch that here.
        run: |
          if grep -q 'opentelemetry, "~> 1.7"' mix.exs; then
            echo "::error::loosen step did not match mix.exs — update otel-compat.yml literals"
            exit 1
          fi
      - name: Resolve the latest published OpenTelemetry (ignore the lock)
        run: |
          mise exec -- mix deps.unlock opentelemetry opentelemetry_api
          mise exec -- mix deps.get
      - name: Show the resolved version (heads-up in the log)
        run: mise exec -- elixir -e 'IO.puts("resolved opentelemetry: " <> to_string(Application.spec(:opentelemetry, :vsn)))'
      - name: Run the OTel bridge tests against latest
        run: |
          mise exec -- mix test \
            test/image_pipe/telemetry/trace/open_telemetry_exporter_test.exs \
            test/image_pipe/telemetry/trace/open_telemetry_integration_test.exs
        env:
          MIX_ENV: test
```

Red here is a heads-up (a new OTel release moved something), not a release blocker — the runtime gate already protects hosts. **Note the layering:** Dependabot (Step 1) and the runtime `@tested_range` gate are both capped at `< 2.0.0` by our dep constraint, so **this job is the only layer that sees a breaking major** — hence the in-job constraint loosening. When it goes red on a new major, that's the deliberate signal to evaluate + widen the dep constraint and `@tested_range` together.

- [ ] **Step 3: Commit.**

```bash
git add .github/dependabot.yml .github/workflows/otel-compat.yml
git commit -m "ci(telemetry): dependabot + scheduled latest-OTel compatibility job"
```

---

## Task 9: Full gate

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

- **Compile-time optionality** (Task 1 `optional: true`, **no `only:`** + the `SpanRecord` `Code.ensure_loaded?(:otel_span)` guard) keeps hosts-without-OTel compiling *and* lets a host-provided OTel activate (the optional-dep edge orders its compile before ours). All `:otel_*`/`Record.extract`/`elem(tracer, 3)` references live **inside `SpanRecord`'s `if` branch** — the one quarantined module. If a step moves any of them out (into the exporter or outside the `if`), the prod build breaks. The exporter itself has no compile guard (it only delegates + checks versions).
- **Canary discipline** (Tasks 3/5): the only internal-shape couplings are `Record.extract(:span, from_lib:)` and `elem(tracer, 3)`, both in `SpanRecord`. The structural-contract tests (Task 3 Step 7) pin them with localized messages; the integration test exercises them end-to-end. The runtime `@tested_range` gate + Task 8 currency tooling are the upgrade-safety net.
- **Safety test must not be vacuous** (Task 5): the signed-URL helper must drive a real request; the `raise`-not-`[]` stub + the `assert values != []` guard enforce this.
- **Cross-consumer correlation** (Task 3 Step 8) is the test for the *whole point* — one `Trace.Span` → LogExporter and OTel share `{trace_id, span_id}`. If it goes red, the product requirement (span-level log↔trace join) is broken.
- **Type consistency:** `SpanRecord` defines `available?/0` + `export/1` in **both** `if`/`else` branches (identical signatures); `OpenTelemetryExporter` defines `available?/0`, `ready?/0`, `export/1`, `version_supported?/1` (no guard — delegates to `SpanRecord`). `ready?/0` is the `@optional_callbacks` member from Task 2. Only `OpenTelemetryExporter` is boundary-exported; `SpanRecord` is not.
