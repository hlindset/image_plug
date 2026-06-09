# OpenTelemetry Exporter (opt-in, optional-dependency bridge) — Design

- **Date:** 2026-06-09
- **Status:** Approved design, pre-implementation
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

That one gap is fatal because of a single span that already crossed the wire:
`Trace.ReqStep` published our outbound **client** span's `span_id` in the
downstream request's `traceparent`, and the downstream service set its root's
parent to that id. The collector therefore already references that exact
`span_id`; if the SDK re-mints it on export, the downstream subtree orphans.
(Purely *internal* spans could tolerate re-minting — only their own, also-exported,
children reference them — but the boundary-crossing client span cannot, and a
hybrid that pins only that span would have to thread OTel's minted parent ids back
by hand. Uniform record injection is cleaner. The genuinely API-only alternative
is the opposite direction: let OTel own *all* ids and have `ReqStep` read OTel's
context for the header instead of `Trace.Id` — a rewrite of #175 that makes OTel
mandatory for propagation. Rejected for scope, see §10.)

Setting a span's own id requires entering at the SDK span-record + span-processor
level, which lives in `:opentelemetry`, not `:opentelemetry_api`.

**Consequence:** our optional dep is the **SDK** (`:opentelemetry`), not just the
API. This is slightly unusual for a library, but it is acceptable here because
(a) it is `optional: true` — never forced on a host, and (b) any host that wants
OTLP export is already running the SDK anyway. Documented as a deliberate
tradeoff, not an oversight.

```elixir
# mix.exs — first use of the optional: true pattern in this repo
{:opentelemetry, "~> 1.x", optional: true},      # SDK: span record + processor
{:opentelemetry_api, "~> 1.x", optional: true},  # transitive; pinned explicitly
# version line pinned during planning against the installed OTel
```

Present when *we* compile/test (so the exporter compiles and the round-trip test
runs); not forced onto hosts.

## 4. Module & boundary

`ImagePipe.Telemetry.Trace.OpenTelemetryExporter` — entirely inside the
`telemetry` boundary. **No new boundary edges**: #175 already owns `Trace.Exporter`
and `deps: []` on the telemetry boundary stays empty. A sibling to `LogExporter`;
nothing else in the library references it.

Public surface on the module:

- `@behaviour ImagePipe.Telemetry.Trace.Exporter` — `export/1`.
- `available?/0` — `Code.ensure_loaded?(:otel_span)` (or the chosen SDK module);
  the presence gate.
- `ready?/0` — exporter-side activation check (see §6); returns `true` only when
  `available?/0`.

Export from the telemetry boundary alongside the #175 set (it is host-named in
`attach_tracer`, so it must be a public entry point). `Trace.LogExporter` stays
unexported per #175; this one is exported because the host names it directly.

## 5. The span mapping (`export/1`) — the actual work

`export(%Trace.Span{} = span)` builds one OTel span and submits it to the host's
configured span processor, then returns `:ok`. Field by field:

| `Trace.Span` (#175 §4) | OTel | Note |
|---|---|---|
| `trace_id` (16 bytes / 32 hex) | 128-bit trace id | `:binary.decode_unsigned/1`; **ours, verbatim** |
| `span_id` (8 bytes / 16 hex) | 64-bit span id | verbatim — must equal the `traceparent` `ReqStep` injected |
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
`exporter.ready?/0` when exported and raises a clear `ArgumentError`
("`:opentelemetry` is not loaded; add it to your deps to use
`OpenTelemetryExporter`") if it returns `false`. This is the smallest change that
turns "OTel absent" from a per-request runtime crash into a startup-time,
actionable error, and it's reusable by any future optional-dep exporter.

- Default exporter stays `LogExporter`/none. Detection never changes the default.
- The host must have **started the OTel SDK** with a span processor + OTLP
  exporter configured (standard host responsibility, same "host owns the backend"
  contract as everything else here). If they configured the noop provider, our
  spans are dropped by the SDK — expected, documented, not our bug.

## 7. The one spike to retire before implementation

**Confirm the exact `:opentelemetry` API for injecting a span with pre-chosen
trace/span IDs, explicit start/end timestamps, and a set parent, into the host's
configured span processor.** This is the only unverified mechanic and it gates
the whole approach.

- **Candidate:** construct the SDK `span` record (`opentelemetry/include/otel_span.hrl`)
  with our IDs as integers and our timestamps in the SDK's representation, then
  submit it to the registered span processor's `on_end/2` (via the tracer
  provider). Pin field names and the timestamp representation against the
  *installed* OTel version — exactly the "check against real upstream source, not
  just internal correctness" discipline the review-cycle rule requires.
- **Timestamp representation** is the subtle sub-part: the SDK stores span times
  in a native/offset form it converts to unix-nanos at export. We must hand it
  times in that form derived from our `start_time`/`end_time` (and `duration_native`
  for honesty), not naive nanos, or durations will be wrong.
- **Fallback if the SDK injection path proves too brittle across versions:** the
  brainstormed escape hatch is the "DIY OTLP writer" (build OTLP `ResourceSpans`
  ourselves). It preserves IDs trivially but reimplements batching/transport, so
  it is the fallback, not the plan. The spike's job is to confirm we don't need it.

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
- **Activation gate:** `attach_tracer(exporter: OpenTelemetryExporter)` raises a
  clear `ArgumentError` when `ready?/0` is `false`. Kept **light** per the test
  guidelines — we don't fabricate the "dep genuinely absent at compile time" host
  scenario (our test env has OTel); we test the `ready?/0`-false branch directly.

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
  If `attach_tracer` gains the `ready?/0` probe, that is an internal change to the
  already-exported `Trace.Exporter` contract — no new export. Architecture test:
  the exporter must **not** alias `Transform.Operation.*` (operation structs reach
  it as opaque terms and are `inspect`ed, never matched) — same invariant #175
  asserts for the capture side.

## 10. Risks & tradeoffs

- **SDK-internals coupling (highest).** Injecting a span record with our IDs uses
  SDK-level structures, not the stable API. Mitigation: the §7 spike pins it
  against the installed version; the integration test catches breakage on upgrade;
  the DIY-OTLP fallback exists if the path closes off.
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

## 11. Build order — single plan

1. `mix.exs`: add `:opentelemetry` / `:opentelemetry_api` as `optional: true`
   (pin versions); confirm they resolve in dev/test.
2. **Spike (§7):** prove span-record injection with our IDs + timestamps into the
   test span processor. Land it as the first integration test so the mechanic is
   verified before the mapping is fleshed out.
3. `OpenTelemetryExporter` `export/1` + the §5 mapping + §5.1 coercion; unit tests.
4. `Trace.Exporter` `c:ready?/0` optional callback + `attach_tracer/1` probe +
   the clear `ArgumentError`; `available?/0`/`ready?/0` on the exporter; gate test.
5. Integration: SDK + pid processor + real `ImagePipe.call/2`; ID preservation,
   nesting, scope, known-duration, and the safety invariant at the OTel boundary.
6. Docs/guideline/cookbook/boundary sync (§9) + architecture test for the
   no-`Transform.Operation.*`-alias invariant.
7. Full `mise run precommit`.
