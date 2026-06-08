# Telemetry Span Capture & Tracing Layer — Design

- **Date:** 2026-06-09
- **Status:** Approved design (reviewed), pre-implementation
- **Scope:** Three phased implementation plans / PRs along the §14 seams

## 1. Problem & goals

ImagePipe already emits a clean tree of `:telemetry.span/3` spans rooted at
`[:image_pipe, :request]` (see `docs/telemetry.md`). We want an **opt-in capture
layer** that consumes those events, reconstructs distributed-trace-shaped spans
with correct parent/child nesting, and hands each finished span to a pluggable
exporter so a host can render its own UI/format or map to Jaeger/Tempo/OTLP.

This is **not** an OpenTelemetry export task. OTel is the reference model for the
span shape and W3C `traceparent` wire format; the deliverable is our own capture +
correlation + propagation + export contract.

### Goals

- Reconstruct correct span nesting within each process and across ImagePipe's
  request-scoped process hops (request → SourceSession, request → Producer), while
  keeping shared-process cache-maintenance spans out of the request trace (§8.1).
- OTel-shaped internal span model so a later Jaeger/Tempo/OTLP map is mechanical.
- Logical **and** physical (Finch wire) spans for outbound source fetches.
- Opt-in inbound `traceparent` extraction so ImagePipe can be a middle hop.
- Honest timing for libvips' lazy pipeline: explicit materialization-barrier spans.
- Ship the same way as the default Logger: opt-in, stdlib-only default exporter,
  third-party backends attached by the host.

### Non-goals

- No sampling logic in our layer (defer to the host SDK; we only propagate the
  inbound sampled flag).
- No third-party backend integration in the library (host attaches OTel/APM).
- No tree-buffering / pretty-tree rendering in the default exporter (flat, stateless).
- No demo UI change (host observability only, no transform/parser option added).

## 2. Confirmed facts the design relies on (verified in code)

- `:telemetry.span/3` runs its handler **synchronously, inline** in the emitting
  process, and adds `telemetry_span_context` (an `make_ref()`) to start/stop/
  exception. That context **matches a single span's events only — it carries no
  parentage**.
- **Process topology (corrected after review — there are FOUR live processes, not
  one hop):**
  - **Plug request process** emits `[:request]`, `[:parse]`, `[:cache, :lookup]`
    (`runner.ex:66`), `[:send]`; holds the inbound `Conn`.
  - It blocks on `GenServer.call` → **SourceSession GenServer process**, which is
    **not** a pure coordinator: it emits `[:cache, :write]` from
    `handle_producer_result` (`sink.ex:161` via `source_session.ex:298`).
  - SourceSession `spawn_link`s the **Producer process**, which emits
    `[:source, :fetch_decode]`, `[:source, :fetch]`, `[:transform, :execute]`,
    `[:transform, :operation]`, `[:transform, :materialize]` (new), `[:transform,
    :detect[, :model]]`, `[:output, :negotiate]`.
  - A long-lived **Admission GenServer** (separate process, reached via
    `GenServer.call` at `file_system.ex:265`) emits `[:cache, :admission]`
    (`admission.ex:505`), `[:cache, :warm_start]` (`admission.ex:140`, in `init/1`,
    outside any request), and the ticker one-shots `[:cache, :flush|:cleanup, :stop]`
    (timer-driven, no request context).

  So there are **two request-scoped hops to thread** (request → SourceSession for
  `[:cache, :write]`; request → Producer for the bulk), plus the Admission process
  whose spans are **deliberately not part of the request trace** (§8.1).
- **Detection is fully synchronous** (`Composite.detect/3` uses `Enum.map`, no
  `Task`/`spawn`) — no fan-out propagation needed; the stack covers detect spans.
- **Materialization runs inside the operation span:** `chain.ex` wraps
  `run_operation` in `[:transform, :operation]`; `run_operation` →
  `maybe_materialize` → `Materializer.materialize/1` (`copy_memory`). Only the
  first materializing op flushes (`materialized?: true` short-circuits). The flush
  is real pixel work but is a **barrier cost** (accumulated upstream lazy work), not
  an op cost, and whether it fires is runtime state invisible from the op name.
- Finch (Req's adapter) emits `[:finch, :request|queue|connect|send|recv, …]` in
  the **caller** process; Req itself emits no telemetry. `meta.request` is the full
  `%Finch.Request{}`; Req's `:finch_private` populates `Finch.Request.private`.

## 3. Architecture

All modules under `ImagePipe.Telemetry.Trace.*` (telemetry boundary). Nothing
attaches automatically; with no tracer attached, zero events match → zero cost.

```
inbound traceparent (opt-in) ─┐
                              ▼
:telemetry [:image_pipe,…] ─▶ Trace.Capture.handle_event/4  (sync, in-proc)
                                  │  push/pop Trace.Stack (process dictionary)
:telemetry [:finch,…]      ─▶ Trace.FinchCapture.handle_event/4
                                  │  parent via finch_private (no stack)
                                  ▼
                              Trace.Span ──▶ Exporter.export/1
                                                ├─ Trace.LogExporter (stdlib, flat)
                                                └─ host OTLP/APM exporter (host-wired)
```

### Module layout

| Module | Purpose |
|---|---|
| `Trace.Context` | immutable, serializable `{trace_id, span_id, trace_flags, baggage}` crossing seams |
| `Trace.Span` | captured span handed to the exporter |
| `Trace.Id` | id generation (`:crypto.strong_rand_bytes`) |
| `Trace.W3C` | `traceparent` encode/decode |
| `Trace.Stack` | per-process active-span stack (process dictionary) |
| `Trace.Capture` | `attach_many` handler for `[:image_pipe, …]` span + one-shot events |
| `Trace.FinchCapture` | `attach_many` handler for `[:finch, …]` events, parented via `finch_private` |
| `Trace.ReqStep` | Req request/response/error steps: inject `traceparent`, open logical client span, stamp `finch_private` |
| `Trace.Exporter` (behaviour) | `@callback export(Trace.Span.t()) :: :ok` |
| `Trace.LogExporter` | stdlib `Logger` default, one flat structured line per span |

Plus host-facing entry points on `ImagePipe.Telemetry`:
`attach_tracer/1`, `detach_tracer/0`.

### Public API

```elixir
ImagePipe.Telemetry.attach_tracer(
  exporter: MyApp.OTLPExporter,   # required; module implementing Trace.Exporter
  prefix: [:image_pipe],          # default: configured prefix
  extract_inbound: false,         # opt-in inbound traceparent extraction
  finch_spans: true               # physical wire spans via FinchCapture
)
ImagePipe.Telemetry.detach_tracer()
```

Options validated with `NimbleOptions`; unknown options rejected. `exporter` must
be a loaded module exporting `export/1`. Like its sibling `attach_default_logger/1`,
`attach_tracer/1` **raises `ArgumentError`** on invalid options (host-startup config
boundary — raise, not a tagged return).

## 4. Span model

`Trace.Span` (OTel-shaped):

- `trace_id` (16 bytes, 32 hex), `span_id` (8 bytes, 16 hex), `parent_span_id`
  (`nil` = root)
- `name` (e.g. `"image_pipe.transform.materialize"`), `kind`
  (`:internal | :server | :client`)
- `start_time` (wall-clock from `system_time`), `end_time`,
  `duration_native` (raw monotonic — the honest timing source)
- `status` (`:unset | :ok | :error`), `status_message`
- `attributes` (filtered; see §6), `events` (one-shots + exceptions), `links`
- `pid`, `node`

## 5. Capture mechanism

`Trace.Capture` is one `attach_many` (module fn; `:telemetry.detach` before
re-attach), dispatching on the event suffix.

- **`:start`** — parent = `Stack.current()`. If stack empty: use an inbound context
  if `Trace.put_inbound/1` left one in the process dict (§9), else mint a fresh
  `trace_id` (root). Otherwise inherit parent's `trace_id` and use its `span_id` as
  `parent_span_id`. Push the new span (stashing `telemetry_span_context` for the
  pairing check).
- **`:stop` / `:exception`** — `:telemetry.span/3` emits exactly one of these (never
  both), so the terminator pops once. Within a correct single-process stack the LIFO
  discipline alone gives right parentage; the stashed `telemetry_span_context` is
  **only** a corruption guard for a dropped/un-propagated event (mismatch ⇒ log +
  skip rather than mis-nest), not load-bearing for nesting. Pop, check the ref,
  finalize duration + status, `exporter.export/1`.
- **One-shots** (`[:cache, :stage]`, `[:output, :clamp]`, `[:http_cache, …]`) — no
  span context; fold as timestamped `events` onto `Stack.current()`. **Guard the
  empty stack:** if `Stack.current()` is `nil` (e.g. a ticker-driven cache one-shot
  fired on a process with no open span), drop the one-shot — never invent a parent.
  `:exception` also folds an `exception` event before finalizing `:error`.

**Status mapping:** stop metadata `result: :ok` → `:ok`; an error atom
(`:cache_error`, `:processing_error`, …) or an `:exception` → `:error` +
`status_message`.

**Honesty tags:** `[:transform, :operation]` spans get `timing: :construction`
(libvips lazy — duration is construction structure, not compute). The materialize
barrier span (§7) carries real flush timing.

## 6. Attribute safety (allowlist, day one)

`safe_attrs/1` copies only known-safe keys (operation structs, dimensions, class
names, cache keys, model-artifact names, result atoms, `output_mode`, `operation`,
`index`). It **drops** full source URLs, request paths, signatures, tokens — any
secret-bearing value. Cardinality is irrelevant; *sensitivity* is the bar
(CLAUDE.md telemetry guideline). Allowlist-by-default means anything unenumerated
(incl. PII / secret-embedding strings) is dropped automatically. Constraints:

- Applied **uniformly** to start metadata, stop metadata, **and** one-shot event
  metadata before folding — not just operation spans.
- Operation structs are stored as **opaque `term()`** (store/inspect only); the
  telemetry boundary must **not** alias `ImagePipe.Transform.Operation.*` — that
  would invert the dependency (telemetry `deps: []` stays empty).
- Confirm the URL/path carriers — `request_metadata` (`plug.ex:43,115`) and
  `source_metadata` (`source.ex:63,85`) — expose no key on the allowlist.

Locked by a test asserting a signed source URL never reaches `attributes`.

## 7. Materialization-barrier span (transform enrichment)

Emit a `[:transform, :materialize]` span **inside
`ImagePipe.Transform.Materializer.materialize/1`** — the single flush site, so it
covers the chain's `maybe_materialize`, the `PlanExecutor` orientation-flush
boundary, and the delivery backstop `materialize_for_delivery/2`. The span's
duration is the real `copy_memory` flush cost.

**Failure mapping (corrected):** `materialize/1` returns tagged
`{:error, {:materialize_error, _}}` as a *value*, not a raise (see `chain.ex:73,82`).
So a flush failure arrives as a `:stop` with an error result → mapped to `:error`
status (§5), **not** an `exception` event. An `exception` event only fires if
`copy_memory` actually *raises*. Both must be handled.

**Nesting is not always under an operation span:** mid-chain materialize nests under
`[:transform, :operation]`; the `PlanExecutor` boundary flush nests under
`[:transform, :execute]`; the delivery backstop (`processor.ex:33`, after the
`execute` span has closed) and an EXIF-only-no-op flush nest under the **producer
root** (`[:request]` via the adopted context). All three are honest about where the
flush fired; the tests (§12) assert each case separately.

`telemetry_opts` is already on `State` (`state.ex:41`, populated at
`plan_executor.ex:62`, read at `crop.ex:175`) and both flush call sites pass a full
`State` — so use `state.telemetry_opts`; **no threading and no arity change** to
`materialize/1`. This is a **new telemetry event** on the transform boundary and
carries doc-sync obligations (§11).

## 8. Cross-process propagation

Thread a `Trace.Context` **as data** alongside the existing `$callers` chain. The
context cannot ride the process dictionary across `DynamicSupervisor.start_child` or
`spawn_link` — it must travel through the call/opts and be re-adopted in the child's
entry, exactly like `owner`/`$callers` do today.

1. **Capture (Plug process).** The `[:request]` span is open on the Plug stack
   throughout `do_call` → `Runner.run` → `start_session` (confirmed: `plug.ex:43`
   wraps everything). Capture `Trace.Stack.context()` at the `start_session` call
   (`runner.ex` ~L35). It's an immutable value, so the parent id is stable even
   though the Plug process then blocks on `GenServer.call` while the child runs.
2. **Hop A — request → SourceSession (for `[:cache, :write]`).** `start_session`
   goes through `DynamicSupervisor.start_child` (`source_session_supervisor.ex:31-37`),
   so the context must travel as a field in the per-session opts/`Request` that
   `SourceSession.init/1` reads (the same path `owner` takes at
   `source_session_supervisor.ex:35`). In `init/1`, beside
   `Process.put(:"$callers", …)` (`source_session.ex:84`), `Trace.Stack.adopt(ctx)`.
   The `[:cache, :write]` span (emitted from `handle_producer_result`) then nests
   under `[:request]`.
3. **Hop B — SourceSession → Producer (for the bulk).** SourceSession forwards the
   context to `Producer.start_link` (already passing `caller_chain`); in the Producer
   `spawn_link`, beside `Process.put(:"$callers", caller_chain)` (`producer.ex:31`),
   `Trace.Stack.adopt(ctx)`. Every producer-process span nests under `[:request]`.

`Trace.Stack.adopt/1` seeds the empty far-side stack with a synthetic remote-parent
frame carrying the context's `trace_id` + `span_id`. Both hops adopt the **same**
request context, so SourceSession's `[:cache, :write]` and the Producer subtree are
siblings under `[:request]` — matching the real causal structure.

### 8.1 Admission GenServer spans — deliberately not in the request trace

`[:cache, :admission]` is behind a `GenServer.call` into a shared, long-lived
Admission process (`file_system.ex:265` → `admission.ex:505`); `[:cache, :warm_start]`
fires in that process's `init/1` (cache startup, no request); the ticker one-shots
`[:cache, :flush|:cleanup, :stop]` fire on its timers. These are **shared-process /
lifecycle** events, not part of any one request's causal chain. Decision: do **not**
thread request context into the Admission process. Each such span becomes its own
fresh root (stack empty ⇒ mint a `trace_id`); the ticker one-shots hit the empty-stack
guard (§5) and are dropped. This is documented behavior, not a gap — threading a
per-request context into a multiplexed shared GenServer would mis-attribute it.

## 9. Finch + Req (logical + physical)

- `Trace.ReqStep` (applied where `source` builds its Req client):
  - **request step** — open a logical client span (kind `:client`), inject
    `traceparent` header from its ids, stamp
    `finch_private: %{image_pipe_trace: {trace_id, span_id}}`.
  - **response step** — close with `http.status_code`; fold redirects/retries as
    `events` (each hop/attempt with its status + `location`).
  - **error step** — close `:error` for transport errors (Req surfaces these via
    error steps, not exceptions).
- `Trace.FinchCapture` — second `attach_many` on `[:finch, …]`. Events fire in the
  Producer process, but parent is taken from `meta.request.private[:image_pipe_trace]`
  (**not** the stack) — robust across retries/redirects/concurrency. Builds wire
  spans (`request`/`queue`/`connect`/`send`/`recv`) under the logical Req span.
  Gated by `finch_spans: true`.

The logical Req span opens in the request step and closes in the response/error
step. If the Producer is hard-killed mid-fetch (`Process.exit`, e.g. owner-down at
`source_session.ex:391`), neither closing step runs: the span is **dropped** (never
exported), not leaked (the dead Producer's process dict is discarded). A killed
fetch losing its in-flight client span is acceptable; documented here so it isn't
mistaken for a bug.

## 10. Inbound edge (opt-in) & sampling

- When `extract_inbound: true`, `plug.call` reads `traceparent`/`tracestate` off the
  `Conn` and calls `Trace.put_inbound(ctx)` **before** the `[:request]` span opens;
  the capture root `on_start` adopts `trace_id` + `parent_span_id` + the sampled
  flag. Malformed/absent header → ignored, fresh root minted (fail-safe). Default
  (disabled) always mints our own root.
- **Sampling is deferred to the host SDK.** We always build the span and call
  `export/1`. The inbound sampled bit rides in `trace_flags` and propagates onward
  (into outbound `traceparent`) but does not gate recording.

## 11. Docs / demo / boundary sync (CLAUDE.md rules)

- `docs/telemetry.md`:
  - A dedicated `### Materialization barrier span ([:transform, :materialize])`
    subsection (not a bare list entry): stop metadata, the `:error`/`materialize_error`
    result on failure, and the parenting nuance (mid-chain under an op span; boundary
    flush under `[:transform, :execute]`; delivery flush under the request root).
    Keep the result-atom list (`telemetry.md` ~L196-219) non-stale.
  - A dedicated `## Tracing (opt-in)` section parallel to `## Attaching handlers`:
    `attach_tracer/1` / `detach_tracer/0`, **every** option (`exporter`, `prefix`,
    `extract_inbound`, `finch_spans`), the `prefix` default reusing `default_prefix/0`,
    and the `Trace.Exporter` `export/1` contract (returns `:ok`; attribute-sensitivity
    expectations mirroring the custom-detector note).
- `ImagePipe.Telemetry.Logger` — all four sync points:
  - **Subscription:** add `[:transform, :materialize]` to `@group_span_events.transform`
    (`logger.ex:16`); the machinery auto-derives `:stop` + `:exception`.
  - **Rendering:** rely on the generic `message/3` fallback (`logger.ex:175`) which
    prints `label` + `outcome/1` — no new clause (a custom clause would risk swallowing
    the outcome). State this choice explicitly.
  - **Levels (the blocking point):** a materialize **`:exception`** is already
    escalated to `:warning` by the generic `:exception` arm (`logger.ex:111`) — record
    that we checked. But a materialize **`:stop` carrying an error result**
    (`{:materialize_error, _}` returned as a value, not raised) would log at **base
    level silently** — so add a `level_for/3` arm escalating a materialize stop-error
    (mirroring the `:cache_error` special-case at `logger.ex:111`).
  - **Coverage:** `logger_test` assertions for both — `refute log =~ "[warning]"` on a
    successful flush stop, `assert log =~ "[warning]"` on the stop-error and on the
    exception (synthetic `:telemetry.execute`, matching the detect/clamp test style).
- **Demo UI: no change** (observability only; no transform/parser option changed).
- **imgproxy conformance: no change** — the materialize span *observes* the existing
  pipeline; it adds no processing behavior, knob, or pixel/stage divergence
  (confirmed by the compatibility reviewer; the flush itself is already documented at
  stage 7 `rotateAndFlip` and the `fixSize`/`limitScale` notes in
  `docs/imgproxy_support_matrix.md`). Optional nicety (non-blocking): a one-line
  mention in the stage-7 note that the barrier now emits `[:transform, :materialize]`,
  paralleling how `[:output, :clamp]` is named there.
- **Boundary:** tracer in the telemetry boundary (`deps: []` stays empty).
  `source → telemetry`, `request → telemetry`, `transform → telemetry` deps **already
  exist** (`source.ex:6`, `request.ex:14`, `transform.ex:13`) — no facade needed; drop
  that fallback. Add to the telemetry boundary's `exports:` exactly: `Trace.Context`,
  `Trace.Stack`, `Trace.Span`, `Trace.Exporter`, `Trace.ReqStep`. Keep `Trace.Capture`,
  `Trace.FinchCapture`, `Trace.Id`, `Trace.W3C`, `Trace.LogExporter` **unexported**.
  The architecture test asserts this export set and that `Trace.Capture`/`FinchCapture`
  subscribe by event-name only (never aliasing emitter modules).

## 12. Testing strategy

Wire-level via real `ImagePipe.call/2` + a `TestExporter` that sends spans to the
test pid:

- Full-tree: one `trace_id`; `[:source, :fetch]` and the transform subtree parented
  under `[:request]` across hop B; `[:cache, :write]` parented under `[:request]`
  across hop A (sibling to the Producer subtree); error → `status: :error`; exception
  folded as an event.
- Materialize nesting, **three separate cases** (the span isn't always under an op):
  - mid-chain materializing op (e.g. smart-crop / right-angle rotate) → `materialize`
    span nested under `[:transform, :operation]`, nonzero duration;
  - delivery-only flush (an EXIF orientation 3–8 source with no other random-access
    op) → `materialize` span present, parented to the **request root**, not an op span;
  - pure-lazy + orientation-1 pipeline (resize/scale only, no deferred EXIF) → **no**
    `materialize` span (negative control; the orientation-1 source ensures the delivery
    flush doesn't fire).
- `[:cache, :admission]` / `[:cache, :warm_start]` appear as their own roots, not
  under `[:request]` (asserts §8.1).
- Attr safety: a signed source URL never appears in any span's `attributes`
  (property + example).
- Inbound: `traceparent` + enabled → root adopts `trace_id`; malformed → fresh;
  default (disabled) → fresh.
- Finch wire spans parented to the logical Req span via `finch_private`.
- Unit: `Id`/`W3C` round-trip and sizes; `Stack` push/pop/adopt incl. a
  nested-then-sibling sequence; status mapping.
- `logger_test` assertion for the new `materialize` line.

**Tests not to write** (CLAUDE.md): no impossible-internal-misuse structs, no
name/existence policing, no post-migration parity pins, no private-error-string
assertions, no source-text scanning outside the architecture test.

## 13. Risks & tradeoffs

- **Process-dictionary leak** if a span opens without a matching stop (a hop that
  bypasses `:telemetry.span/3`, or `Process.exit`). Mitigation: process death
  discards the dict; pairing-ref check catches mismatches; depth cap + warn. A
  hard-killed Producer drops its in-flight logical Req span (§9) — acceptable.
- **Forgettable propagation** — a future spawn/Task that doesn't thread context
  orphans. Mitigation: two request hops today (§8), both threaded; `bind/async`
  helpers + an architecture test guard; orphan-root detection in tests.
- **Cache topology is the subtle part** — `[:cache, :write]` (SourceSession) needs
  hop A; admission/warm_start/ticker spans are intentionally separate roots (§8.1).
  Getting this wrong silently orphans cache spans; covered by the §12 assertions.
- **Finch span volume** — `finch_spans: true` multiplies spans; it's gated and the
  default can be reconsidered if noisy.
- **Sensitive-data regression** is the highest-stakes failure — locked by the
  attr-safety test; every new attribute is guideline-reviewed; operation structs
  stored opaque (no `Transform.Operation.*` alias in telemetry).

Resolved during review (no longer open): `source → telemetry` dep already exists;
`State.telemetry_opts` is already reachable at the flush site.

## 14. Build order — three phased plans (each its own review + PR)

The test surface spans five boundaries; per review it decomposes into three plans
along natural seams. The materialize span + its **full** Logger/doc-sync stay in
Phase 1 (the only piece with CLAUDE.md doc-sync teeth — don't let the Levels arm slip
under Finch/inbound review fatigue).

**Phase 1 — core capture + materialize barrier + Logger/doc sync:**
1. `Trace.Id`, `Trace.W3C` (+ unit tests).
2. `Trace.Context`, `Trace.Span`, `Trace.Stack` (+ unit tests incl. nested-then-sibling).
3. `Trace.Capture` + `Trace.Exporter` + a `TestExporter`; single-process wire-level
   tree test via real `ImagePipe.call/2`.
4. `safe_attrs/1` (opaque structs, uniform application) + attr-safety test.
5. `[:transform, :materialize]` span in `Materializer` (use `state.telemetry_opts`) +
   the four Logger-sync points (incl. the stop-error `level_for/3` arm) +
   `telemetry.md` materialize subsection + the three-case materialize tests.

**Phase 2 — cross-process propagation + inbound edge:**
6. Hop A (request → SourceSession, threaded as data through `start_child` opts →
   `init/1`) and Hop B (SourceSession → Producer); §8.1 Admission-as-separate-root;
   cross-process tree test (`[:cache, :write]` + Producer subtree under `[:request]`).
7. Inbound edge (`extract_inbound`, `put_inbound`, plug extraction, malformed→fresh) +
   tests.

**Phase 3 — outbound HTTP + public glue + docs:**
8. `Trace.ReqStep` + `Trace.FinchCapture` (logical + physical via `finch_private`) +
   Finch tests.
9. `Trace.LogExporter` + `logger_test`; `ImagePipe.Telemetry.attach_tracer/1` (raising
   validation) + `detach_tracer/0`; `telemetry.md` `## Tracing (opt-in)` section.
10. Boundary defs + `exports:` set + architecture test; full `mise run precommit`.
