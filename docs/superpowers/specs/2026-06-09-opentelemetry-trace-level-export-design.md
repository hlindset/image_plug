# OpenTelemetry Export (trace-level, public-API replay) — Design

- **Date:** 2026-06-09
- **Status:** Approved design, pre-implementation
- **Supersedes:** `2026-06-09-opentelemetry-exporter-design.md` (the span-id-preserving
  FFI design — reverted). Read that doc's §2/§3 for the full reasoning trail behind the
  decision relaxed here.
- **Builds on:** `2026-06-09-telemetry-span-tracer-design.md` (#175). #175 captures a
  product-neutral tree of finished `%Trace.Span{}` structs with cross-process
  trace_id/parent already resolved, and hands each to a pluggable `Trace.Exporter`
  (`export/1`). `LogExporter` is the existing one; this adds an OTel one.

## 1. The decision that shapes everything

**Correlation is trace-level, not span-level.** Logs (`LogExporter`) and OTel spans
share the **`trace_id`** for the same request; they do **not** share the **`span_id`**.
You can pivot "all logs for trace T" ↔ "the OTel trace T", but not "this exact log line"
↔ "this exact OTel span". This was a deliberate relaxation (the prior design preserved
`span_id` at the cost of hand-building SDK-internal records).

Everything good follows from it:

- **`trace_id` is settable through the public OTel API** (a span inherits its parent
  context's trace_id). **A span's own `span_id` is not** — but we no longer need to set
  it. So we drop entirely out of SDK internals and onto the **public API**.
- The exporter stays a **`Trace.Exporter`** (host attaches it via `attach_tracer/1`,
  exactly like `LogExporter`) — "just another attached exporter", no new model.
- We replay each **finished** `%Trace.Span{}` as an OTel span via the public API. Because
  #175 already resolved cross-process trace_id + parent into each finished span, replay is
  **stateless and per-span** — no buffering, no live handler, no cross-process glue.

### Goals
- A built-in `ImagePipe.Telemetry.Trace.OpenTelemetryExporter` (`Trace.Exporter`) that
  replays finished spans into a host-running OTel SDK via the **public API only**.
- **Compile-time dependency on `:opentelemetry_api`** (the lightweight API), declared
  `optional: true`. The host brings the SDK (`:opentelemetry`) at runtime.
- Preserve the **trace_id** (so logs/metrics/OTel group into one trace); let OTel mint
  span_ids.
- Opt-in inbound `traceparent` (inherited from #175's `extract_inbound`).

### Non-goals
- **No span-id preservation** (the whole FFI/internal-records apparatus — gone).
- **No SDK-internals coupling** → no `@tested_range` version gate, no structural-contract
  tripwires, no Dependabot/`otel-compat` currency tooling. The public API is stable; the
  internal records were not. All of that disappears.
- **No `opentelemetry_telemetry`** (see §3).
- No transport/batching/sampling of our own (host SDK owns it). No demo/imgproxy change.
- No new telemetry events, no Logger change.

## 2. Why the public-API replay works (spike — verified against opentelemetry-erlang 1.7 / API 1.5)

The make-or-break — *does an out-of-band span actually export?* — is **confirmed**. A span
created with `start_span(ctx, …)` and ended with `end_span(span_ctx, end_time)` flows
through the on-start/on-end processors → exporter **without ever being the process's
current span** (`otel_span_ets:start_span/7` inserts into the span table and runs on-start
processors; `end_span/2` takes it and runs on-end processors — both keyed by the span_ctx,
not the context stack). This is the same code path `with_span` uses internally, minus the
attach/detach. All calls live in **`:opentelemetry_api`**.

**Use the Elixir API surface.** `:opentelemetry_api` ships both the Elixir modules
(`OpenTelemetry.Tracer`, `OpenTelemetry.Span`, `OpenTelemetry`) and the Erlang modules they
wrap — same package. We use the idiomatic Elixir wrappers for tracer/span/status/event. The
**only** Erlang-direct call is the synthetic-traceparent extraction
(`:otel_propagator_text_map.extract_to/3` + the W3C codec), which has **no** Elixir wrapper —
it's the one piece of the API that only ships as an Erlang function (not a drop to a
different library).

**Per-span replay shape** (parent and root identical except the synthetic parent id):

```elixir
require OpenTelemetry.Tracer, as: Tracer
alias OpenTelemetry.Span

# Remote-parent context carrying OUR trace_id. extract_to/3 has no Elixir wrapper — the
# one Erlang-direct call (same :opentelemetry_api package). The Tracer.start_span macro
# resolves the instrumentation scope from our app (get_application_tracer) → "image_pipe".
parent_ctx =
  :otel_propagator_text_map.extract_to(
    :otel_ctx.new(),
    :otel_propagator_trace_context,           # pass the W3C codec explicitly — don't rely on host propagator config
    [{"traceparent", "00-#{trace_hex}-#{parent_hex}-01"}]   # -01 sampled flag is MANDATORY (see §2.1)
  )

span_ctx =
  Tracer.start_span(parent_ctx, span.name, %{
    start_time: native_start,
    kind: kind,
    attributes: attrs,
    links: links
  })

Span.set_status(span_ctx, OpenTelemetry.status(status_code, status_message))
Span.add_events(span_ctx, events)              # events built via OpenTelemetry.event/3 (explicit timestamps)
Span.end_span(span_ctx, native_end)            # explicit end time
```

The minted `span_id` is discarded (we don't need it). The trace_id comes from the parent
context, so **our** trace_id wins. (`OpenTelemetry.Tracer.start_span/3` is a macro — hence
`require` — that injects `get_application_tracer(__MODULE__)`, giving the span the
`image_pipe` instrumentation scope automatically; no manual `get_tracer` call needed.)

### 2.1 Constraints the spike pinned (load-bearing)
- **`extract_to/3`, not `extract/2`.** `extract/2` calls `otel_ctx:attach/1` and mutates
  the process context stack; `extract_to/3` returns a fresh context without attaching.
  Replay must not touch the emitting process's current span.
- **Synthetic traceparent must be `-01` (sampled).** The default `parent_based` sampler
  routes a `-00` remote parent to `always_off` → the span is **dropped, never exported**.
  Always emit `-01`.
- **Thread the SDK-returned `span_ctx`.** The setters/`end_span` no-op unless given the
  exact `span_ctx` returned by `start_span` (it carries the `span_sdk` handle). Don't
  hand-build a span_ctx.
- **Pass the W3C codec explicitly** to `extract_to/3` (`:otel_propagator_trace_context`)
  so we don't depend on the host having configured a global propagator.
- **Timestamps are native monotonic.** `start_time`/`end_span` want
  `erlang:monotonic_time()`-frame values. #175's `Trace.Span.start_time` is `system_time`
  (= monotonic + offset), so `native = start_time - :erlang.time_offset()`, and
  `end = native + duration_native`. (Same conversion the prior design used — it's just a
  time value now, not a record field.)
- **Attribute coercion still required.** The public `set_attributes`/`add_event` path
  *validates and silently drops* non-primitive values, so to keep an opaque operation
  struct (as an `inspect`-ed string) we coerce to primitives first — same `coerce/1` logic
  as before, same product-neutral safety story (sensitivity already handled by #175's
  `safe_attrs/1`).

### 2.2 The root-span wart (acceptable)
A true root (no parent context) always gets a freshly-minted trace_id — there is no public
way to set a parentless span's trace_id. So to force **our** trace_id on #175's root span,
we give it a **synthetic remote parent** (`00-<our trace_id>-<our root span_id>-01`). The
root then renders with a dangling "remote parent" reference. For trace-level grouping this
is correct and standard (it's how a continued trace looks); exact root-nesting is the thing
we already agreed to give up.

## 3. Why not `opentelemetry_telemetry`

`opentelemetry_telemetry` is the idiomatic bridge for turning **live** `:telemetry` span
events into OTel spans — its value is reconstructing single-process span *lifecycle/nesting*
from start/stop events. **We don't need that**, for two reasons:

1. **#175 already did it, better.** It hands us *finished* spans with nesting and
   **cross-process** trace_id/parent already resolved (`opentelemetry_telemetry` is
   single-process only and would re-root our Producer subtree as a separate trace). Using
   it would mean re-solving cross-process correlation it can't actually solve.
2. **It would invert the model.** It's a live raw-event handler, not a `Trace.Exporter`;
   adopting it abandons #175's stateless finished-span exporter seam and adds per-process
   trace-id seeding glue. The public-API replay keeps the clean `export/1` shape.

So `opentelemetry_telemetry` is the right tool for a library that *doesn't* already have
#175's capture layer. We do. Replay is simpler and reuses it. (Recorded as considered-and-rejected.)

## 4. Module & boundary

One module, no FFI quarantine needed (there are no internals to quarantine):

`ImagePipe.Telemetry.Trace.OpenTelemetryExporter` — `@behaviour Trace.Exporter`. Inside the
`telemetry` boundary (`deps: []` unchanged; calls only the external `:opentelemetry_api`
package — `OpenTelemetry.*` + the two propagation Erlang functions — and `Trace.Span`). A
**compile guard** `if Code.ensure_loaded?(OpenTelemetry.Tracer)` wraps the public-API calls
(the `require OpenTelemetry.Tracer` macro and the `extract_to` call) so a host *without*
`:opentelemetry_api` still compiles ImagePipe; the `else` branch makes `export/1` a no-op
and `available?/0` false. Surface:

- `@impl export/1` — replay (§2), or no-op when OTel absent.
- `available?/0` — `Code.ensure_loaded?(OpenTelemetry.Tracer)`.
- `@impl ready?/0` — `available?/0`. **No version gate** — the public API is stable across
  the OTel 1.x line, unlike the internal records the prior design rode. (Re-adds the
  optional `c:ready?/0` callback on `Trace.Exporter`, as the prior design did.)

Export only `OpenTelemetryExporter` from the telemetry boundary (host-named in
`attach_tracer`).

## 5. Activation, deps, absence

- Host: `attach_tracer(exporter: OpenTelemetryExporter, extract_inbound: true)` — the #175
  entry point, unchanged. `attach_tracer` probes `ready?/0` and raises a clear
  `ArgumentError` if `:opentelemetry_api` isn't loaded.
- Deps (`mix.exs`): `{:opentelemetry_api, "~> 1.x", optional: true}` only — **not** the SDK.
  For our own tests we add `{:opentelemetry, "~> 1.x", only: :test}` (the SDK, to actually
  record/export and assert) + the simple-processor test config. The host brings the SDK in
  their own deps.
- The host must have **started the OTel SDK** (processor + exporter). If not, the API
  degrades to a noop tracer and `extract_to`/`start_span` produce nothing — no crash,
  documented.

## 6. The mapping (`export/1`)

| `Trace.Span` | OTel (public API) |
|---|---|
| `trace_id` / `parent_span_id` (hex, `parent` may be `nil`) | synthetic `traceparent` → `extract_to/3` parent context. Root (`nil` parent) uses `span.span_id` as the synthetic parent (§2.2). |
| own `span_id` | **discarded** (OTel mints its own) |
| `name`, `kind` (`:internal`/`:server`/`:client`) | `start_span` opts (`name`, `kind` 1:1) |
| `start_time` / `duration_native` | `start_time: start - time_offset()`; `end_span(_, start - time_offset() + duration_native)` |
| `status` (`:unset`/`:ok`/`:error`) + `status_message` | `OpenTelemetry.status/2` → `set_status` |
| `attributes` | coerced to primitives → `set_attributes` (drop/`inspect` non-primitives; add `image_pipe.pid`/`image_pipe.node`) |
| `events` (`%{name:, time:, attributes:}`) | `OpenTelemetry.event/3` (explicit native ts) → `add_events`; exception event has no `:time` → fall back to end |
| `links` | `[]` today (#175 emits none) |

Instrumentation scope: tracer `:image_pipe` via `:opentelemetry.get_tracer/1` (or
`get_application_tracer`); version from `Application.spec`.

## 7. Testing

Wire it the same way the prior design did (config: SDK `span_processor: :simple,
traces_exporter: :none`; per-test `:otel_simple_processor.set_exporter(:otel_exporter_pid,
self())`; spans arrive as `{:span, rec}`). Read the exported `#span{}` in tests via
`Record.extract` (test-only — reading what the SDK delivers, not constructing it):

- **Canary / id behavior:** export one `%Trace.Span{}`, assert the received span carries
  **our** `trace_id` (integer-decoded) and an OTel-minted `span_id` that is **non-zero and
  not equal** to our span_id (proves OTel minted its own — the opposite of the old design's
  assertion). Assert name/kind/status/duration map correctly.
- **Cross-consumer correlation (the product requirement, relaxed):** fan one span to
  `LogExporter` + `OpenTelemetryExporter`; assert the **trace_id** matches (log `trace=` ↔
  OTel trace_id), and explicitly assert the **span_ids differ** (documents the accepted
  trade — trace-level, not span-level).
- **Sampled-flag guard:** assert a span exports (we emit `-01`); a regression to `-00`
  would make `refute_receive` fire — worth one explicit test that the span *does* arrive.
- **Safety invariant:** a signed source URL never appears in any exported attribute
  (coercion `inspect`s opaque terms — re-assert at the OTel boundary).
- **Gate:** `attach_tracer(exporter: OpenTelemetryExporter)` with a not-ready exporter
  raises (generic, in `attach_test.exs`).
- **E2E:** real `ImagePipe.call/2` → all exported spans share one trace_id (reuse #175 wire
  fixtures). No deep-nesting assertion (trace-level only).

**No** structural-contract / version-range / currency tests — there are no internals to
guard.

## 8. Docs / boundary / guideline sync

- **CLAUDE.md telemetry guideline:** same narrow carve-out as before (opt-in,
  optional-dependency OTel bridge exporter; ships adapter code only). Even cleaner now: the
  dep is the *API*, and we use only its public surface.
- **`docs/telemetry.md`:** `### OpenTelemetry export` subsection — `attach_tracer(exporter:
  …)`, the `:opentelemetry_api` optional dep + host brings the SDK, **trace-level
  correlation** (shared trace_id; span_ids are OTel's), inbound `traceparent`, the
  SDK-started precondition.
- **`docs/cookbook/opentelemetry-jaeger.md`:** Jaeger all-in-one recipe (host adds
  `:opentelemetry` + exporter, points OTLP at Jaeger, one `attach_tracer` call).
- **Logger / demo / imgproxy:** no change.
- **Boundary:** telemetry `deps: []` unchanged; export `Trace.OpenTelemetryExporter`. The
  no-`Transform.Operation.*`-alias invariant is Boundary-enforced (no bespoke test).

## 9. What this removes vs the superseded FFI design

Gone: the `SpanRecord` FFI module, `Record.extract`/`#span{}` construction, `elem(tracer, 3)`,
the `@tested_range` runtime version gate, the structural-contract tripwire tests, the
Dependabot + `otel-compat` currency tooling, and the SDK (`:opentelemetry`) as a runtime
dependency (now API-only at compile time). Kept: `Trace.Exporter` model, `ready?/0` gate
(presence only), attribute coercion, native-time conversion, the safety/correlation tests
(retargeted to trace-level), the Jaeger cookbook.

## 10. Risks & tradeoffs

- **Trace-level only (the accepted trade).** No log↔OTel span-level pivot; root spans
  render with a dangling remote parent; cross-process subtrees group by trace_id but aren't
  deep-nested. Documented as the deliberate choice.
- **Sampled-flag footgun.** Emitting `-00` silently drops every span. Mitigation: always
  `-01`; the §7 "span does arrive" test catches a regression.
- **Host must start the SDK.** API-without-SDK silently produces nothing. Documented
  precondition; not our bug.
- **Public-API stability.** Low risk — `start_span`/`end_span`/`extract_to`/`status` are the
  stable public surface (this is the entire point of moving off internals). A loose
  `:opentelemetry_api` constraint is fine; no version gate needed.

## 11. Build order — single plan
1. `mix.exs`: `:opentelemetry_api` optional (compile) + `:opentelemetry` `only: :test`
   (SDK, for tests) + test SDK config. `deps.get`.
2. Re-add `c:ready?/0` optional callback on `Trace.Exporter`.
3. `OpenTelemetryExporter` (compile-guarded) + the §6 replay mapping + coercion; canary test
   (our trace_id, OTel-minted span_id) — verify-first.
4. Mapping fidelity tests (duration, status, coercion, sampled-flag-arrives, undeliverable).
5. `attach_tracer` `ready?/0` probe + gate test; boundary export.
6. E2E (one trace_id across a real request) + trace-level correlation test + URL safety.
7. Docs/cookbook/guideline sync.
8. Full `mise run precommit`.
