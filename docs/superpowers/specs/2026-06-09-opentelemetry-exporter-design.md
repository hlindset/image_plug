# OpenTelemetry Exporter (opt-in, optional-dependency bridge) — Design

> **⛔ SUPERSEDED (2026-06-09) by
> `2026-06-09-opentelemetry-trace-level-export-design.md`.** This design preserved
> ImagePipe's `span_id` into OTel (for span-level log↔trace correlation), which forced
> hand-building SDK-internal `#span{}` records — the quarantined FFI, version gate, and
> currency tooling below. The decision was later **relaxed to trace-level-only
> correlation** (logs and OTel share the `trace_id`, not the `span_id`), which removes
> the need to set a span's own id and lets the exporter use the **public** OTel API
> only. The FFI implementation was reverted. **Kept as the reasoning trail** — it is the
> full justification for *why* trace-level was chosen and what span-level would have
> cost. Do not implement from this document.

- **Date:** 2026-06-09
- **Status:** SUPERSEDED — see banner above (reverted, not implemented)
- **Scope:** One new `Trace.Exporter` implementation + a small `Trace.Exporter`
  contract extension + docs/cookbook/guideline sync. Single plan.
- **Builds on:** `2026-06-09-telemetry-span-tracer-design.md` (#175). That layer
  already owns the trace model, ID generation, W3C propagation, and the
  `Trace.Exporter` seam. This is purely a second exporter behind it.

## 1. Problem & goals

#175 ships an opt-in span-capture layer that hands each finished `Trace.Span`
to a pluggable `Trace.Exporter` (`@callback export(Trace.Span.t()) :: :ok`), with
a stdlib `Trace.LogExporter` as the only built-in. We want a built-in exporter
that ships those spans to an **OTLP collector** (Jaeger, Tempo, an OTel
Collector, …) so a host can see ImagePipe's traces in real tooling without
writing the OTLP mapping themselves.

The constraint that shapes everything: **#175 already owns the trace/span IDs**
(`Trace.Id`) and already injects W3C `traceparent` outbound via `Trace.ReqStep`.
So whatever path we use, **OpenTelemetry must accept our IDs verbatim** — or the
spans we export won't stitch to the `traceparent` we already put on downstream
HTTP calls, and the whole point (a coherent distributed trace) is lost.

### Goals

- A built-in `ImagePipe.Telemetry.Trace.OpenTelemetryExporter` implementing the
  existing `Trace.Exporter` behaviour — a thin translator, nothing more.
- **Optional dependency, presence-detected.** ImagePipe declares OTel as
  `optional: true`; the host pulls it in. The exporter is only usable when OTel
  is loaded.
- **Gate availability, not auto-activation.** Detection decides whether the
  exporter *can* run. The host still opts in explicitly via the existing
  `attach_tracer(exporter: …)`. Matches the "never attached automatically"
  stance shared with the default Logger. Default exporter stays `LogExporter`.
- **Preserve our trace/span IDs** end to end, so exported spans stitch to the
  `traceparent` `ReqStep` already injects.
- A **Jaeger local-dev cookbook** entry so a developer can stand up
  all-in-one and see traces.

### Non-goals

- No transport, batching, retry, sampling, or resource detection of our own — the
  host's OTel SDK owns all of that. We feed it finished spans.
- No demo UI change (host observability only; no transform/parser option).
- No imgproxy conformance change (this observes, adds no processing behavior).
- No new telemetry events and **no Logger change** (no new event names; the
  Logger subscribes to events, not exporters).
- No auto-wiring when OTel is merely present (rejected during brainstorming).

## 2. Decisions locked during brainstorming

**The contract (canonical identity).** ImagePipe's canonical tracing identity is the
product-neutral `Trace.Span` identity. Every observer of a logical operation — the
`LogExporter`, metrics, custom exporters, **and** OpenTelemetry — must see the same
`{trace_id, span_id}` pair, because that pair is the **join key** that correlates a log
line to its exact span (OTel's own model defines a span context as precisely
`{trace_id, span_id}`). The Erlang/Elixir OTel API has no supported per-span id
override, so the OTel exporter is permitted a **quarantined SDK-internals adapter** to
emit completed spans under the canonical ids. This keeps the core product-neutral and
preserves span-level log↔trace correlation. The id-preservation is justified by this
cross-consumer join key — **not** by outbound `traceparent` propagation to (usually
dumb) origins.

| Fork | Decision |
|---|---|
| Placement | **In-library, optional dep.** Ships in `lib/` as a sibling to `LogExporter`; `:opentelemetry` declared `optional: true`; runtime `Code.ensure_loaded?/1` detection (same pattern as `source/s3/credentials.ex:16`, the vision detectors). |
| Transport | **Bridge into the OTel SDK.** Convert each finished `Trace.Span` to an OTel span and hand it to the host's configured span processor. SDK owns batching/retry/OTLP/transport/resource. |
| Activation | **Gate availability; host opts in.** Detection only enables an explicit opt-in; absence yields a clear error at attach time, not a runtime crash. |
| Cookbook | Own file: `docs/cookbook/opentelemetry-jaeger.md`. |
| `pid`/`node` | Mapped to span attributes (product-neutral, non-sensitive, useful for reading cross-process nesting), not dropped. |

## 3. The dependency consequence (record it honestly)

Normal Elixir instrumentation libraries depend only on the lightweight
`:opentelemetry_api` and emit through `OpenTelemetry.Tracer` macros, letting the
SDK mint IDs. **We can't** — we must inject spans that already carry *our* IDs
and timestamps.

The blocker is narrower than "IDs" and worth stating precisely. The API *does*
let the caller pin the **`trace_id`**: a remote parent context (exactly what
inbound `traceparent` extraction builds) makes a started span inherit that
`trace_id` and take the remote span's id as its **`parent_span_id`**. What the
API never exposes is a span's **own `span_id`** — that is always freshly minted
by the SDK's id-generator. So via the API we could pin the trace and a span's
parent, but never a span's own identity.

That one gap matters because **span identity is the join key across every observer
of a logical operation** (§2 contract). The `LogExporter`, metrics, custom exporters,
and OTel all consume the same `%Trace.Span{}` and must surface the same
`{trace_id, span_id}`. If the SDK re-mints `span_id` on export, OTel becomes an
**identity-island**: its spans share only the `trace_id` with our logs, so you can
group by trace but never pivot from a log line to the span that emitted it. Because
logs reference **every** span (not just boundary-crossers), this is all-or-nothing —
every exported span must carry our id, which is exactly uniform record injection.
(A secondary, much weaker reason: `ReqStep` also publishes the client span's `span_id`
in the outbound `traceparent`, so an instrumented origin would orphan under
re-minting — but for typical S3/nginx origins that rarely matters. The join key, not
propagation, is load-bearing. The genuinely API-only alternative is the opposite
direction — let OTel own *all* ids and have every `Trace.Span` consumer read OTel's
context, making OTel the canonical id source — but that couples the product-neutral
core to OTel and breaks the standalone `LogExporter`; see §10.)

Setting a span's own id requires entering at the SDK span-record + span-processor
level, which lives in `:opentelemetry`, not `:opentelemetry_api`.

**Consequence:** our optional dep is the **SDK** (`:opentelemetry`), not just the
API. This is slightly unusual for a library, but it is acceptable here because
(a) it is `optional: true` — never forced on a host, and (b) any host that wants
OTLP export is already running the SDK anyway. Documented as a deliberate
tradeoff, not an oversight.

```elixir
# mix.exs — first use of the optional: true pattern in this repo
{:opentelemetry, "~> 1.7", optional: true},      # SDK: #span{} record + processors
{:opentelemetry_api, "~> 1.5", optional: true},  # transitive; pinned explicitly
# The dep constraint is the *resolvable* range. Activation is separately gated at
# runtime against a narrower @tested_range (§6) — a host on an untested newer 1.x
# resolves fine but the exporter refuses to activate (loud raise) rather than emit
# possibly-malformed spans. Compile-time Record.extract catches field *renames* (build
# fails); the runtime gate + canary (§8) cover semantic drift the compiler can't see.
```

Present when *we* compile/test (so the exporter compiles and the round-trip test
runs); not forced onto hosts.

## 4. Module & boundary

Two modules, both inside the `telemetry` boundary (so `deps: []` stays empty; no new
boundary edges — #175 already owns `Trace.Exporter`). The split is deliberate: it
makes the unsafe SDK-internals code an **FFI boundary** with a one-file blast radius.

- **`ImagePipe.Telemetry.Trace.OpenTelemetryExporter`** — the clean `Trace.Exporter`
  impl. Behaviour callbacks, activation/gating, and the `%Trace.Span{}` → neutral
  mapping. **Knows nothing about OTel record internals**; delegates the actual record
  construction + processor call to `SpanRecord`. This is the host-named, exported
  module.
- **`ImagePipe.Telemetry.Trace.OpenTelemetry.SpanRecord`** — the **quarantined**
  module, and the *only* place in the codebase that touches SDK internals:
  `Record.extract(:span, …)`, `elem(tracer, 3)`, the `:span`/`:status`/`#event{}`
  shapes, the constructor calls, and the native-time conversion. Carries a loud
  "UNSUPPORTED SDK bridge — version-pinned, may break on OTel upgrade" moduledoc. Not
  exported from the boundary (internal helper to the exporter).

Public surface on `OpenTelemetryExporter`:

- `@behaviour ImagePipe.Telemetry.Trace.Exporter` — `export/1`.
- `available?/0` — `Code.ensure_loaded?(:otel_span)`; the presence gate.
- `ready?/0` — activation gate (§6): `available?/0` **and** the running OTel version is
  in `@tested_range`. Returns `false` (→ `attach_tracer/1` raises) otherwise.

Export only `OpenTelemetryExporter` from the telemetry boundary (it is host-named in
`attach_tracer`). `SpanRecord` and `Trace.LogExporter` stay unexported.

## 5. The span mapping (`export/1`) — the actual work

`export(%Trace.Span{} = span)` builds one OTel span and submits it to the host's
configured span processor, then returns `:ok`. Field by field:

| `Trace.Span` (#175 §4) | OTel | Note |
|---|---|---|
| `trace_id` (32-hex **string**) | 128-bit trace id (int) | `String.to_integer(hex, 16)`; **ours, verbatim** |
| `span_id` (16-hex **string**) | 64-bit span id (int) | `String.to_integer(hex, 16)`; verbatim — the cross-consumer join key (§2 contract) |
| `parent_span_id` (`nil` = root) | parent span id / root | |
| `name` | span name | e.g. `"image_pipe.transform.materialize"` |
| `kind` `:internal`/`:server`/`:client` | OTel span kind | 1:1 |
| `start_time` / `end_time` | span start/end | converted to the SDK's expected timestamp representation (§7 spike) |
| `status` `:unset`/`:ok`/`:error` + `status_message` | OTel status | |
| `attributes` | OTel attributes | **coerced** to primitives (§5.1) |
| `events` (folded one-shots + exceptions) | OTel span events | name + timestamp + coerced attributes |
| `links` | OTel links | trace/span id refs |
| `pid`, `node` | attributes `image_pipe.pid`, `image_pipe.node` | per §2 decision |

Instrumentation scope: name `"image_pipe"`, version from
`Application.spec(:image_pipe, :vsn)`. The host's **Resource** (`service.name`
etc.) is applied by the SDK at export — not our concern.

### 5.1 Attribute coercion (load-bearing)

#175 stores operation structs as **opaque `term()`** in `attributes` (so the
telemetry boundary never aliases `Transform.Operation.*`). OTel attribute values
must be primitives (string / integer / float / boolean / arrays thereof). So the
mapping must coerce:

- numbers / booleans / binaries → pass through;
- atoms → string;
- structs / other terms (the opaque operation structs) → `inspect/1` string;
- nested → flatten or `inspect/1`.

Applied uniformly to span attributes **and** event attributes. This coercion is
the only non-mechanical part of the map and gets its own unit test. **Sensitivity
is already handled upstream** by #175's `safe_attrs/1` allowlist — by the time a
value reaches us it is non-secret — so coercion is a *type* concern, not a safety
one. (We still assert the safety invariant end-to-end in §8.)

## 6. Activation & graceful absence

Host activates through the **existing** #175 entry point — no new public verb:

```elixir
ImagePipe.Telemetry.attach_tracer(
  exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
  extract_inbound: true   # optional, as in #175
)
```

The gate: extend the `Trace.Exporter` behaviour with an **optional** callback
`c:ready?/0 :: boolean` (default `true` when not implemented). `attach_tracer/1`
— which already validates the exporter module and **raises `ArgumentError`** on
bad config (#175 §3, host-startup boundary) — additionally calls
`exporter.ready?/0` when exported and raises a clear `ArgumentError` if it returns
`false`. This turns a missing/incompatible OTel from a per-request runtime crash into
a startup-time, actionable error, and it's reusable by any future optional-dep
exporter.

`OpenTelemetryExporter.ready?/0` checks **two** things, and raises with the specific
reason:

1. **Presence** — `Code.ensure_loaded?(:otel_span)`. Absent → "`:opentelemetry` is not
   loaded; add it to your host deps."
2. **Tested version range** — `Version.match?(otel_vsn, @tested_range)`, where
   `@tested_range` (e.g. `"~> 1.7"`) is the range we have actually canary-tested the
   record/closure shapes against, and is *narrower* than (or equal to) the dep
   constraint. A host on an untested newer 1.x → "OTel <vsn> is outside ImagePipe's
   tested range <range>; refusing to emit possibly-malformed spans." `otel_vsn` comes
   from `Application.spec(:opentelemetry, :vsn)`.

We **raise** rather than silently degrade: the host explicitly opted into OTel via
`attach_tracer`, so a hard, named failure at startup is correct — not "quietly run
without tracing." (Loud-disable, per the agreed contract.)

- Default exporter stays `LogExporter`/none. Detection never changes the default.
- The host must have **started the OTel SDK** with a span processor + OTLP
  exporter configured (standard host responsibility, same "host owns the backend"
  contract as everything else here). If they configured the noop provider, our
  spans are dropped by the SDK — expected, documented, not our bug.

## 7. Injection mechanism (spike retired — verified against opentelemetry-erlang)

Researched against `open-telemetry/opentelemetry-erlang` source (current hex:
`:opentelemetry` 1.7.0, `:opentelemetry_api` 1.5.0). **Finding: there is no
public API to record a span with a caller-supplied `span_id`.** Every public path
(`OpenTelemetry.Tracer.start_span`, `otel_tracer:start_span`, `otel_span:*`) mints
IDs through the per-provider-global `otel_id_generator` (callbacks take no args, so
they can't target "the span whose id I pre-published"). The `start_opts()` map has
no `span_id`/`trace_id` key. So the bridge **must construct the SDK's internal
`#span{}` record and run the host's configured span processors over it.** This is
how internal SDK code and other bridges do it; it means coupling to internal
records — recorded as the top risk (§10).

**The mechanism (all verified):**

1. **Construct `#span{}`** (`opentelemetry/include/otel_span.hrl`) via
   `Record.extract(:span, from: "deps/opentelemetry/include/otel_span.hrl")` — by
   field name, so field reordering doesn't break us. Key fields:
   - `trace_id` / `span_id` / `parent_span_id` — **plain integers** (128-bit /
     64-bit / 64-bit). Decode our hex with `String.to_integer(hex, 16)`. **These
     are written to the wire verbatim** (`<<TraceId:128>>` / `<<SpanId:64>>` in
     `otel_otlp_traces.erl`, no re-minting) — the whole point.
   - `kind` — the `?SPAN_KIND_*` atoms (`:INTERNAL`/`:SERVER`/`:CLIENT`).
   - `status` — a `#status{code, message}` record (`opentelemetry.hrl`).
   - `attributes` / `events` / `links` — **wrapper records, not bare
     maps/lists**; build via `:otel_attributes.new/3`, `:otel_events.new/3` +
     `:opentelemetry.event/3`, `:otel_links.new/4` + `:opentelemetry.link/4`.
     Never hand-build these (their internal shape is a known migration boundary).
   - `trace_flags: 1` — **must have the sampled bit set or the processor silently
     drops the span** (`?IS_SAMPLED` guard in `otel_simple_processor.on_end`).
   - `is_recording: false` (the span is finished).
   - `instrumentation_scope` — set the `#instrumentation_scope{name, version}`
     record field directly (name `"image_pipe"`, version from `Application.spec`);
     with the inject approach `start_span` never stamps it for us.
2. **Run the host's processors.** `:opentelemetry.get_tracer(:image_pipe)` returns
   `{:otel_tracer_default, tracer_record}` (or `{:otel_tracer_noop, []}` if the SDK
   isn't running — see below). Read the `on_end_processors` closure off the
   `#tracer{}` record and call it with our `#span{}`. The `#tracer{}` record is an
   SDK-internal shape, so rather than extract its header we read the field **by
   position** (`elem(tracer, 3)`; fields are `module, on_start_processors,
   on_end_processors, …`) and let the §8 integration canary guard the position. That closure folds over **whatever**
   processors the host configured (simple in tests, batch in prod) — so the same
   code path serves both; we don't hard-code a processor. (Only the `#span{}` record
   itself is read by field name, via `Record.extract(… from_lib:
   "opentelemetry/include/otel_span.hrl")` — a public `include/` header.)
3. **Noop / SDK-not-started guard.** If `get_tracer` returns the noop tuple (dep
   present but SDK app not started, or noop provider configured), drop the span —
   `available?/0` (`Code.ensure_loaded?(:otel_span)`) only proves the dep is
   *loaded*, not that a real provider is running. `export/1` matches the tracer
   tuple and no-ops on noop. Documented, not a bug.

**Timestamp conversion (the subtle correctness point).** The `#span{}`
`start_time`/`end_time` are **Erlang native-unit `monotonic_time` values**, and
the OTLP exporter re-adds `:erlang.time_offset()` at export. Our `Span.start_time`
is `system_time` (= `monotonic_time + time_offset`, also native), so the
monotonic-frame value the record wants is simply `start_time - time_offset()`:

```elixir
offset = :erlang.time_offset()
start_native = span.start_time - offset
end_native   = start_native + (span.duration_native || 0)   # exact on-wire duration
```

Then `timestamp_to_nano(start_native)` recovers our wall-clock, and the duration
is offset-independent (exports correctly regardless of offset drift). Event
timestamps: our `event.time` is already raw `monotonic_time`, exactly what
`#event{}.system_time_native` expects — no conversion (the exception event carries
no time, so fall back to `end_native`).

**No fallback needed.** The brainstormed DIY-OTLP escape hatch (§10) is no longer
on the table for the happy path — the bridge is verified. DIY-OTLP would also
couple to internal OTLP encoding *and* lose the host's batching/resource pipeline,
so it is strictly worse; it remains only a theoretical exit if a future OTel major
removes the `#span{}`/processor seam entirely.

## 8. Testing strategy

- **Unit — mapping (pure, no SDK):** `Trace.Span` → the intermediate OTel shape;
  assert every field, especially ID byte→int decoding, kind/status mapping, and
  **attribute coercion** (an opaque operation struct becomes an `inspect` string;
  numbers/bools/binaries pass through; `pid`/`node` land as `image_pipe.*`).
- **Integration — ID preservation (the whole point):** start the OTel SDK in test
  with the in-memory / pid test span processor, `attach_tracer(exporter:
  OpenTelemetryExporter)`, run a real `ImagePipe.call/2`, and assert the captured
  OTel spans carry **our** `trace_id`/`span_id` and the correct parent nesting +
  scope. This is what proves the bridge actually preserves IDs.
- **Safety invariant (carried over):** a signed source URL never appears in any
  exported OTel span's attributes — re-assert at the OTel boundary, not just
  #175's `Trace.Span` boundary, since coercion `inspect`s terms (guard against an
  opaque value stringifying a secret).
- **Cross-consumer correlation (the product requirement — new):** fan one
  `%Trace.Span{}` to **both** `LogExporter` and `OpenTelemetryExporter` and assert the
  logged `trace=`/`span=` fields and the exported OTel span carry the **same**
  `{trace_id, span_id}`. This is the regression guard for the entire reason we preserve
  ids (§2 contract) — if a future change lets OTel re-mint, this fails. Without it,
  nothing actually tests that logs and traces join.
- **Structural-contract tests (FFI tripwires — new):** readable assertions in the
  `SpanRecord` test that pin each internal assumption, so an OTel upgrade fails with a
  *localized* message instead of a confusing downstream one: `:opentelemetry.get_tracer/1`
  returns `{:otel_tracer_default, t}` with `elem(t, 3)` a 1-arity fun; the extracted
  `:span` record exposes the fields we set; `:opentelemetry.status(:error, "x") ==
  {:status, :error, "x"}`; `:opentelemetry.instrumentation_scope/3` returns the shape we
  expect. These *are* the canary — they go red the moment the SDK shape moves.
- **Activation gate:** `attach_tracer(exporter: OpenTelemetryExporter)` raises a clear
  `ArgumentError` (a) when `ready?/0` is `false`, and (b) when the running OTel version
  is outside `@tested_range` (inject the version check). Kept **light** — we don't
  fabricate the "dep absent at compile time" host scenario (our test env has OTel); we
  test the `ready?/0`-false and version-out-of-range branches directly.

**Tests not to write** (CLAUDE.md): no impossible-internal-misuse structs, no
name/existence policing (don't assert the module or `available?/0` "exists"), no
post-migration parity pins, no private-error-string assertions, no source-text
scanning outside the architecture test.

## 9. Docs / guideline / boundary sync (CLAUDE.md rules)

This change **softens a stated rule**, so the doc edits are part of the diff, not
an afterthought:

- **CLAUDE.md telemetry guideline** currently says *"Keep third-party backend
  integrations out of the library: hosts attach AppSignal, OpenTelemetry, and
  metrics handlers themselves."* Amend with a narrow carve-out: ImagePipe may
  ship an **opt-in, optional-dependency** OTel *bridge exporter* that contains
  adapter code only and pulls in no dependency on its own — the host still
  provides the SDK and configures the backend. The "never attached automatically"
  and "no hard dep" principles are preserved. **(User approved this carve-out.)**
- **`docs/telemetry.md`** — under the #175 `## Tracing (opt-in)` section, add an
  `### OpenTelemetry export` subsection: the optional deps the host adds, the
  `attach_tracer(exporter: OpenTelemetryExporter)` call, the SDK-started
  precondition, the ID-ownership note (we own IDs; W3C propagation stays
  coherent), the SDK-not-API dependency tradeoff (§3), and that the `ready?/0`
  gate raises if OTel is absent. Soften the "doesn't depend on OpenTelemetry"
  wording to "doesn't *hard*-depend; ships an optional, opt-in OTel bridge."
- **`docs/cookbook/opentelemetry-jaeger.md`** (new): `jaegertracing/all-in-one`
  docker-compose snippet, the host deps to add (`:opentelemetry`,
  `:opentelemetry_exporter`), `config :opentelemetry` pointing the OTLP exporter
  at Jaeger's `4317`/`4318`, and the single `attach_tracer` call. The
  "battery included, you flip the switch" recipe.
- **`ImagePipe.Telemetry.Logger`** — **no change** (no new events).
- **Demo UI** — no change (observability only).
- **imgproxy conformance** — no change (observes; no knob/stage/pixel divergence).
- **Boundary** — telemetry `deps: []` unchanged; add
  `Trace.OpenTelemetryExporter` to the telemetry boundary `exports:` (host-named).
  The `ready?/0` probe is an internal change to the already-exported
  `Trace.Exporter` contract — no new export. The exporter must **not** alias
  `Transform.Operation.*` (operation structs reach it as opaque terms and are
  `inspect`ed, never matched); this is enforced **by Boundary's `deps: []`** at
  compile time (a transform reference fails `mix compile`), so no bespoke
  source-scan test is added — the exporter doesn't subscribe to telemetry events,
  so the #175 capture-side scan doesn't apply to it.

## 10. Risks & tradeoffs

- **SDK-internals coupling (highest, confirmed).** There is no public injection
  API (§7), so we depend on two internal SDK shapes: the `#span{}` record
  (`opentelemetry/include/otel_span.hrl`) and the `on_end_processors` field of the
  `#tracer{}` record. Mitigations: (a) read `#span{}` via `Record.extract(…
  from_lib: "opentelemetry/include/otel_span.hrl")` **by field name** (public
  `include/` header, no relative path), and read only the single
  `on_end_processors` field of `#tracer{}` **by position** (`elem(tracer, 3)`),
  depending on no `#tracer{}` header at all; (b) build
  attributes/events/links only through their constructor functions, never literals
  (their shape is the known migration boundary); (c) **quarantine** all of it in one
  module, `Trace.OpenTelemetry.SpanRecord` (§4) — the only file that imports the
  internals, so the blast radius is one file; (d) gate activation at runtime against a
  narrower `@tested_range`, not just the dep constraint (§6) — an untested version
  **disables loudly** rather than mis-exporting; (e) the §8 **structural-contract +
  integration tests** are the canary — a record/closure shape change goes red with a
  *localized* message before release. The `#span{}` record + processor `on_end/2` have
  been stable across the 1.x line.
- **Depending on the SDK, not just the API (§3).** Unusual for a library;
  accepted because it's optional and OTLP hosts run the SDK anyway. Recorded so a
  future reader doesn't "fix" it down to `:opentelemetry_api` and silently break
  ID preservation.
- **Attribute coercion stringifying a secret.** Low (sensitivity is handled
  upstream by `safe_attrs/1`) but `inspect`ing opaque terms is where a regression
  could surface — locked by the §8 safety invariant test at the OTel boundary.
- **Host misconfiguration (noop provider / SDK not started).** Spans silently
  dropped by the SDK. Not our bug; documented in the cookbook precondition.
- **Timestamp representation wrong → wrong durations.** Part of the §7 spike;
  asserted via a known-duration span in the integration test.

### Staying current with OpenTelemetry (the maintenance contract)

Because we ride SDK internals, "what happens on an OTel release" must be an explicit,
automated process — three layers, defense in depth:

1. **Defensive (runtime).** The `@tested_range` gate (§6): a host on an OTel version we
   haven't blessed gets a loud `attach_tracer` raise, never a malformed span. This is
   the backstop that makes the other two layers non-urgent.
2. **Reactive (per release).** A Renovate/Dependabot config watching `:opentelemetry`
   and `:opentelemetry_api` opens a bump PR on each release. CI runs the
   structural-contract + canary + correlation tests against the new version. **Green** →
   widen `@tested_range` (and the dep constraint if needed) and merge; **red** → the
   localized structural-contract failure points at exactly what moved; adapt
   `SpanRecord`, re-verify, then bless the version.
3. **Proactive (scheduled).** A weekly CI job (`otel-compat.yml`) that resolves the
   **latest** `:opentelemetry` and runs the bridge tests — so we learn a new release
   broke us *before* a host's bug report does. Red here is a heads-up, not a release
   blocker.

**The major-version trap (important).** Both the runtime `@tested_range` gate *and*
Dependabot are bounded by the `mix.exs` dep constraint (`~> 1.7` → `< 2.0.0`), so
neither can see a breaking **2.0**. That's correct for the gate (refuse the untested
major) and acceptable for Dependabot (a major bump is a human decision), but it means
the **proactive job is the *only* layer that can catch a major break** — and to do so
it must **loosen the constraint in-job** (rewrite the requirement to `>= 0.0.0` in the
ephemeral checkout) before resolving, with a guard step that fails if the loosen didn't
apply (literal drift). Without that, the job silently reverts to the capped behavior
and passes for the wrong reason. When it goes red on a new major, that's the signal to
evaluate and widen the dep constraint **and** `@tested_range` together.

The discipline: **bumping the tested range is a deliberate act backed by green
structural-contract tests**, never an automatic merge. The gate + the localized tests
are what make "ride internals safely" a real, ongoing contract rather than a
hope-it-doesn't-break.

### Option B as a documented future fallback (not built)

If a conservative host ever wants zero SDK-internals exposure, the public-API path
("own the `trace_id`, let OTel mint `span_id`s") remains available as a **future**
`:public_context_only` mode — accepting **trace-level-only** correlation (logs and OTel
share the trace, not the span). It is **not built now** (YAGNI / greenfield: it's a
second full exporter with its own cross-process context threading, not a config
toggle). `:disabled` is free — simply don't attach. We ship one path
(`:preserve_span_ids`) and document Option B as the named degraded mode to build when a
real host asks.

## 11. Build order — single plan

1. `mix.exs`: add `:opentelemetry` (`~> 1.7`) / `:opentelemetry_api` (`~> 1.5`) as
   `optional: true` (no `only:`); confirm they resolve in dev/test.
2. **`SpanRecord` FFI module + injection canary first (§4/§7):** the quarantined
   `Trace.OpenTelemetry.SpanRecord` — `#span{}`-construct → `on_end_processors` — with
   `:otel_simple_processor` + `:otel_exporter_pid` tests asserting our exact
   `trace_id`/`span_id` arrive, plus the **structural-contract** assertions (tracer
   tuple shape, status/scope constructor shapes). Build the unsafe boundary first and
   pin it before the mapping grows on top.
3. `OpenTelemetryExporter` `export/1` (delegating to `SpanRecord`) + the §5 mapping +
   §5.1 coercion; unit tests.
4. `Trace.Exporter` `c:ready?/0` optional callback + `attach_tracer/1` probe + the
   clear `ArgumentError`; `available?/0` and `ready?/0` (presence **and**
   `@tested_range` version gate) on the exporter; gate + version-out-of-range tests.
5. Integration: SDK + pid processor + real `ImagePipe.call/2`; ID preservation,
   nesting, scope, known-duration, safety invariant, **and the cross-consumer
   correlation test** (one `Trace.Span` → `LogExporter` + OTel share `{trace_id,
   span_id}`).
6. **Currency tooling:** Renovate/Dependabot config for `:opentelemetry`/`_api` + a
   scheduled `otel-compat.yml` CI job resolving latest OTel against the bridge tests
   (§10 "Staying current").
7. Docs/guideline/cookbook/boundary sync (§9). The no-`Transform.Operation.*`-alias
   invariant needs **no** bespoke architecture test: the telemetry boundary's
   `deps: []` already fails `mix compile` on any transform reference, and the
   exporter doesn't subscribe to telemetry events (so the #175 capture source-scan
   doesn't apply). See §9.
8. Full `mise run precommit`.
