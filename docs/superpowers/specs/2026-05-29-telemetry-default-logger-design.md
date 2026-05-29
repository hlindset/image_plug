# Telemetry Default Logger + Per-Operation Transform Spans

## Scope

This slice productizes telemetry-based logging for ImagePipe and reframes the
project's telemetry-metadata guideline around *sensitivity* rather than
*cardinality*. Three coherent, related pieces:

- **`ImagePipe.Telemetry.attach_default_logger/1` + `detach_default_logger/0`** —
  a built-in, **opt-in** `:telemetry` → `Logger` handler covering ImagePipe's
  full event surface (request / parse / source / transform / cache), with
  `:level`, `:events`, `:prefix`, and `:debug` options. Follows Oban's
  `attach_default_logger` model (host opts in), not Phoenix's auto-attach.
- **Per-operation transform tracing spans** — `[:transform, :operation]` spans
  emitted from `ImagePipe.Transform.Chain.execute/2`, replacing the existing
  direct `Logger.debug` in `chain.ex`. Their duration is documented as
  pipeline-*construction* time, not pixel-compute time (libvips is lazy).
- **AGENTS.md guideline rewrite** — (1) reframe the metadata rule around
  sensitivity (secrets / source URLs / filesystem paths) instead of
  cardinality, and (2) allow per-operation transform spans for tracing.

The dev server (PR #114's `ImagePipe.SimpleServer.CacheLogger`) becomes the
first caller of the new public API and the dev-only logger module is deleted.

Out of scope:

- JSON/structured *encoding* in the library (host's `Logger` backend formats;
  no JSON dependency added).
- Per-event log-level overrides, and any metadata-redaction configuration.
- An emit-level "verbose" request option. Transform op metadata is rich by
  default (see below), so no separate opt-in is needed for the known use case.
- Adding telemetry handlers for third-party backends (AppSignal, OpenTelemetry,
  metrics). Those remain the host's responsibility.

## Background & Motivation

### The dev server already proved the pattern

PR #114 added a dev-only `ImagePipe.SimpleServer.CacheLogger` (`dev/cache_logger.ex`)
that attaches a `:telemetry` handler bridging `[:image_pipe, :cache, *]` events
to `Logger`. It works and is exactly the right *mechanism*; it is just dev-only
glue. This slice promotes that mechanism into a documented, prod-compiled,
opt-in public API and widens it to the whole event surface.

### Ecosystem precedent

Telemetry → logging is the idiomatic Elixir pattern; libraries emit events and
optionally ship a default logger:

- **Oban** — `Oban.Telemetry.attach_default_logger/1`, **opt-in** (host calls
  it), with `:level`, `:events`, `:encode` options. We mirror this model.
- **Phoenix** — `Phoenix.Logger`, telemetry-based but **auto-attached /
  opt-out** (`config :phoenix, :logger, false`). We deliberately do *not* copy
  the auto-attach behavior; opt-in matches ImagePipe's "hosts attach handlers
  themselves" stance.

### Metadata: sensitivity is the real constraint, not cardinality

The current AGENTS.md telemetry guideline says "keep telemetry metadata
low-cardinality, product-neutral, and safe by default" and forbids emitting
transform operation params among other things. Investigation during design
showed the cardinality framing does not match how telemetry is actually
consumed, and that the major Elixir libraries emit high-cardinality metadata
routinely:

- **Phoenix** puts the entire `%Plug.Conn{}` (path, query params, headers) in
  `[:phoenix, :endpoint, :stop]` / `[:phoenix, :router_dispatch, :stop]`.
- **Ecto** puts the SQL string *and* bound `:params` in `[:repo, :query]`.
- **Oban** puts the whole `%Oban.Job{}` (including `args`) in
  `[:oban, :job, :stop]`.

Why this is fine, and what actually matters:

- **Cardinality is a non-issue at the emission layer.** Nothing forwards the raw
  metadata map to storage. `Telemetry.Metrics` requires the metrics author to
  *explicitly select* which fields become tags, so rich metadata does not
  auto-propagate into metric labels. Tracing *wants* high-cardinality per-request
  data. Logs are high-cardinality by nature.
- **Sensitivity is the genuine hazard.** Metadata fans out to *every* attached
  handler, including third-party exporters that ship off-box. Anything sensitive
  in metadata can leak to a vendor (this is precisely why Ecto's `params`-in-
  metadata is a documented PII footgun). For ImagePipe the sensitive set is
  narrow and concrete: **signatures / tokens / credentials, full source URLs,
  and path-derived identifiers (filenames, filesystem/storage paths).**
- **Performance is minor if you pass by reference.** Phoenix/Oban put the
  conn/job in metadata essentially for free by passing the existing term. The
  cost only appears if you eagerly serialize a verbose blob on a hot path.

**Consequence for transform params:** an operation struct such as
`%ImagePipe.Transform.Operation.Resize{width: {:pixels, 640}, …}` is
high-cardinality but **not sensitive** — it is derived directly from the public
request URL. So it may be emitted in metadata (passed by reference, cheap). The
default logger shows the operation *name* by default and the *full struct* under
`debug: true`.

## Current State

### `[:image_pipe, *]` event surface (already emitted)

Span events (`:start` / `:stop` / `:exception`, via `ImagePipe.Telemetry.span/4`):

| Group | Events |
|---|---|
| `:request` | `[:request]`, `[:send]` |
| `:parse` | `[:parse]` |
| `:source` | `[:source, :resolve]`, `[:source, :fetch]`, `[:source, :fetch_decode]` |
| `:transform` | `[:transform, :execute]` (coarse pipeline span) |
| `:cache` | `[:cache, :lookup]`, `[:cache, :write]`, `[:cache, :admission]`, `[:cache, :warm_start]` |

One-shot events (`ImagePipe.Telemetry.execute/4`):

| Group | Events |
|---|---|
| `:cache` | `[:cache, :eviction, :stop]`, `[:cache, :flush, :stop]`, `[:cache, :cleanup, :stop]`, `[:cache, :stage]` |

All emitted under the prefix from `telemetry_prefix` opt (default `[:image_pipe]`).
Existing stop metadata is low-cardinality (`result`, `cache`, `output_format`,
`victim_count`, `trigger`, etc.) — no paths/keys/secrets.

### `ImagePipe.Telemetry` (helper, today)

`lib/image_pipe/telemetry.ex` is `@moduledoc false`, `use Boundary, top_level?:
true, deps: [], exports: []`. Provides `span/4`, `execute/4`, `telemetry_opts/1`,
`default_prefix/0`, and internal `clean_metadata/merge_metadata`. A boundary's
main module is always implicitly exported, which is why `request` / `cache` /
`source` code can already call `ImagePipe.Telemetry.span`.

### Transform logging (today) — to be replaced

`lib/image_pipe/transform/chain.ex:42` logs each operation with a direct
`Logger.debug(fn -> "executing transform: #{name} with operation
#{inspect(operation)}" end)`. This bypasses the telemetry contract and inlines
the full operation struct. The coarse `[:transform, :execute]` span lives in the
`request` boundary (`lib/image_pipe/request/processor.ex:82`), not in `transform`.
`transform` is `use Boundary, deps: [ImagePipe.Plan]` — it has no telemetry
dependency, and `chain.ex` is the only place in `transform/` that logs.

### Dev server (today)

`lib/mix/tasks/image_pipe.server.ex` attaches `ImagePipe.SimpleServer.CacheLogger`
via `maybe_attach_cache_logger/1` when `--cache` is on. `dev/simple_server.ex`
exports `CacheLogger`. `dev/cache_logger.ex` is the dev-only handler.

## Design

### Public API

```elixir
# Idempotent (detaches any prior handler with the same id first), so :ok always.
@spec attach_default_logger(keyword()) :: :ok
ImagePipe.Telemetry.attach_default_logger(opts \\ [])

@spec detach_default_logger() :: :ok | {:error, :not_found}
ImagePipe.Telemetry.detach_default_logger()
```

Options:

- `:level` — base `Logger` level for normal events. Default `:info`. Error
  outcomes (e.g. `result: :cache_error`) and `:exception` events escalate to
  `:warning`.
- `:events` — `:all` (default) or a list drawn from `[:request, :parse, :source,
  :transform, :cache]`.
- `:prefix` — the telemetry event prefix to attach to. Default
  `ImagePipe.Telemetry.default_prefix()` (`[:image_pipe]`). Lets a host that
  configures a custom `telemetry_prefix` still use the default logger.
- `:debug` — boolean, default `false`. When `true`, each logged event also emits
  the **full raw `measurements` + `metadata`** (via `inspect/2`) in addition to
  the curated message — a generic "show me everything the event carries" switch.
  Purely consumer-side: it changes nothing about what the library emits and has
  no effect on other handlers.

Idempotency: a fixed handler id (`"image-pipe-default-logger"`). `attach`
detaches any prior handler with that id first, so repeated calls (dev restarts,
tests) do not fail with `:already_exists`. `detach_default_logger/0` removes it.

`attach_default_logger/1` validates options (reject unknown keys / bad `:events`
group / non-list `:prefix`) before attaching — this is host-controlled config at
a boundary, so explicit validation applies.

### Modules & boundaries

- `ImagePipe.Telemetry` becomes a **documented public module** hosting
  `attach_default_logger/1` and `detach_default_logger/0` (its `span`/`execute`
  helpers stay `@doc false`). No boundary export change needed — the boundary
  main module is implicitly exported.
- New private `ImagePipe.Telemetry.Logger` (same `ImagePipe.Telemetry` boundary)
  implements `handle_event/4`, message construction, level mapping, and the
  `:debug` raw dump. It only reads event maps and calls `Logger`; no in-app
  module deps, so the boundary stays `deps: []`.
- `transform` boundary gains `ImagePipe.Telemetry` in `deps` (currently
  `[ImagePipe.Plan]`) so `chain.ex` can emit the per-operation span. This is a
  benign new edge — `ImagePipe.Telemetry` is a `deps: []` product-neutral leaf,
  and the rule "transform → nothing in parser/request/source/cache/output/
  response" is unaffected.
- The dev **mix task** boundary gains `ImagePipe.Telemetry` in `deps` so it can
  call `attach_default_logger/1`.

### Message format & levels

Readable message + structured `Logger` metadata; the host's `Logger` backend
decides plaintext vs JSON. The library never JSON-encodes.

- Message: `"image_pipe <group> <event>: <outcome>"`, e.g.
  `image_pipe cache lookup: hit`, `image_pipe cache write: stored`,
  `image_pipe request: ok`, `image_pipe transform: resize (#1)`.
- Metadata attached to each `Logger` call: `event:` (the event name list),
  `duration_us:` (for span `:stop` events, derived from the `:duration`
  measurement), plus the event's existing stop-metadata fields verbatim
  (`result`, `cache`, `output_format`, `victim_count`, `reason`, `trigger`,
  `operation`, `index`, …).
- Level: normal `:stop` / one-shot events at `:level`; `result: :cache_error` (or
  other error-shaped outcomes) and all `:exception` events at `:warning`.
- `:debug` true: additionally `Logger.debug("image_pipe <event> raw",
  measurements: <map>, metadata: <map>)` (or inline `inspect`), so the full
  payload — including high-cardinality fields like the `operation` struct — is
  visible.

Curated per-group rendering (the human-readable half) mirrors the existing dev
`CacheLogger`, extended to request/parse/source/transform. Exact per-event
strings are an implementation detail; the contract under test is *(level,
substring, key metadata fields)*.

### Per-operation transform spans

`ImagePipe.Transform.Chain.execute/2` wraps each operation in:

```elixir
Telemetry.span(telemetry_opts, [:transform, :operation], %{operation: name, index: i}, fn ->
  {Transform.execute(operation, state), %{result: result_tag}}
end)
```

- Event: `[:transform, :operation]`, nested at runtime inside the coarse
  `[:transform, :execute]` span (same call stack), so an OTel bridge renders them
  as child spans in order.
- Start metadata: `%{operation: <name atom>, index: <0-based position>}`.
  Stop metadata adds `result: :ok | :error`. The **full operation struct** is
  included in metadata as well (passed by reference; not sensitive — see
  Background). The default logger shows the name by default and the struct under
  `:debug`.
- **Duration semantics, documented in `@doc`/moduledoc and AGENTS.md:** the span
  measures pipeline-*construction* time, not pixel work — libvips is lazy and
  fuses/defers compute to materialization/encode. Honest aggregate timing stays
  on `[:transform, :execute]` (build + materialize + validate) and the encode/
  output stage. Per-op duration is for *tracing structure*, not timing.
- The direct `Logger.debug` in `chain.ex` is removed; the per-op breadcrumb is
  now produced by the default logger consuming `[:transform, :operation]`.
- `chain.ex` needs the request/runtime `opts` (for `telemetry_opts/1`,
  i.e. the configured prefix). `Chain.execute/2` already receives the chain;
  it will additionally receive `opts` threaded from `processor.ex`. (Plan step
  will confirm the exact `execute` arity/callers and update them together.)

### Dev server migration

- Delete `dev/cache_logger.ex` and the `CacheLogger` export in
  `dev/simple_server.ex`.
- `lib/mix/tasks/image_pipe.server.ex`: `maybe_attach_cache_logger/1` →
  `ImagePipe.Telemetry.attach_default_logger(events: [:cache, :transform],
  level: :debug, debug: true)`. This preserves what `--cache` shows today (cache
  lifecycle + per-operation transform breadcrumbs, now with full structs under
  `debug: true`) through the real public API. `events`/`debug` here are a
  dev-server choice and easily widened to `:all`.

### AGENTS.md changes

1. **Metadata rule (the "low-cardinality, product-neutral, safe by default"
   bullet + its list)** — reframe around sensitivity:
   - Emit freely, including high-cardinality and product-specific data (operation
     structs, parser structs), because metadata is consumer-projected, not
     forwarded raw to storage.
   - The constraint is **sensitivity**: never emit (without an explicit,
     documented opt-in) signatures / tokens / credentials, full source URLs, or
     path-derived identifiers (filenames, filesystem/storage paths). Cache *keys*
     remain excluded as path/identity-derived.
   - Remove "Transform internals (operation params)" from the forbidden list.
2. **Per-operation transform span rule (line 42)** — replace the blanket ban
   with: per-operation transform spans are allowed for *tracing* execution
   structure; their duration reflects pipeline construction (libvips is lazy),
   not pixel work, and must never be presented as compute timing; keep aggregate
   timing on `[:transform, :execute]`; per-op metadata may include the operation
   struct (not sensitive).
3. **"Keep backend integrations out of the library" bullet** — clarify that an
   **opt-in default `Logger` handler (stdlib `Logger` only)** is permitted and
   shipped; third-party backends (AppSignal, OpenTelemetry, metrics) remain the
   host's responsibility.

### Testing

- `attach_default_logger/1` idempotency (double attach succeeds; handler present
  once); `detach_default_logger/0` removes it; option validation rejects unknown
  keys / bad `:events` / bad `:prefix`.
- One `handle_event/4` assertion per group (cache lookup, cache write, request,
  transform op, an error/exception) via `ExUnit.CaptureLog`: asserts level and a
  message substring + key metadata. `:events` filter excludes a group. `:debug`
  true includes the raw payload (assert the `operation` struct appears).
- `chain.ex`: a test that executing a 2+ operation chain emits
  `[:transform, :operation]` `:start`/`:stop` in order with correct `operation`/
  `index` metadata (attach a test telemetry handler). Confirm the old
  `executing transform:` `Logger.debug` line is gone.
- Architecture/boundary test updated for the new `transform → ImagePipe.Telemetry`
  edge; suite stays green.
- Run focused tests + `mix compile --warnings-as-errors` + `mix credo --strict`.

## Risks / Notes

- **Event names become semi-public contract.** Shipping a documented default
  logger means the `[:image_pipe, *]` event names + metadata fields are now a
  supported surface. Greenfield is the right time to fix their shape; this spec
  treats the current names as the contract.
- **`Chain.execute/2` signature change** ripples to its callers (processor and
  any tests/doctests). The plan must update all callers together; `chain.ex`'s
  moduledoc doctest uses `execute/2` and will need the new arity.
- **Default-logger noise.** With `events: :all` a host gets a line per stage per
  request. Default `:level` is `:info`; hosts scope via `:events`/`:level`. The
  dev server uses `:debug`.
