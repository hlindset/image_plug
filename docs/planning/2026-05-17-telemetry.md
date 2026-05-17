# Telemetry

## Goal

Add stable request and stage telemetry so host applications can observe ImagePlug request lifecycle outcomes and wire AppSignal/OpenTelemetry-style spans from telemetry hooks without coupling to internal modules.

## Why This Matters

ImagePlug currently has strong safety and cache semantics, but limited operational visibility. Telemetry should make production diagnosis easier without changing the core request contract or taking a hard dependency on a tracing backend.

## Proposed Events

Default prefix should likely be `[:image_plug]`, configurable through Plug options. Events should follow `:telemetry.span/3` naming semantics: each span emits `:start`, `:stop`, and `:exception`.

### Level 1: Request Span

- `[:image_plug, :request, :start]`
- `[:image_plug, :request, :stop]`
- `[:image_plug, :request, :exception]`

This is the stable top-level span for a full Plug request.

### Level 2: Stage Spans

Add stage spans for request phases that map to meaningful operational work:

- `[:image_plug, :parse, ...]`
- `[:image_plug, :origin, :identity, ...]`
- `[:image_plug, :cache, :lookup, ...]`
- `[:image_plug, :output, :negotiate, ...]`
- `[:image_plug, :origin, :fetch_decode, ...]`
- `[:image_plug, :transform, :execute, ...]`
- `[:image_plug, :encode, ...]`
- `[:image_plug, :cache, :write, ...]`
- `[:image_plug, :send, ...]`

Each stage should emit the same `:start`, `:stop`, and `:exception` suffixes as the request span.

## Metadata

Metadata should stay low-cardinality and product-neutral. Candidate fields:

- `parser`: parser module.
- `request_method`: HTTP method.
- `cache`: `:disabled`, `:hit`, `:miss`, `:write_skipped`, `:write_error`, or `nil` when not relevant.
- `result`: `:ok`, `:parser_error`, `:plan_error`, `:origin_error`, `:processing_error`, `:cache_error`, or another narrow result atom.
- `status`: response status when known.
- `output_mode`: `:automatic` or `:explicit` when known.
- `output_format`: resolved output format when known.
- `error`: stable error atom or category when known.
- `kind`, `reason`, and `stacktrace`: exception metadata on `:exception` events only.

Avoid full request paths by default because imgproxy-style paths may contain signatures, filenames, or origin-shaped user data. If path metadata is added, make it explicit opt-in configuration and document the high-cardinality/sensitivity tradeoff.

## Operation Timing

Do not include per-operation transform spans in the first pass.

Libvips-backed image operations can be lazy: individual transform calls may only build a processing graph, while materialization or encoding performs the expensive work later. Stage spans are more honest for waterfall charts. Per-operation spans can be considered later as opt-in dispatch/lowering timings, but they should not be presented as precise libvips CPU timings.

## Design Constraints

- Do not emit parser-specific structs or transform internals as metadata.
- Keep metadata stable and product-neutral.
- Avoid changing response behavior.
- If cache hit/miss is reported, expose it through a narrow result category rather than leaking cache adapter internals.
- Runtime code should continue dispatching through boundary-owned modules.
- Use telemetry hooks only; do not add hard AppSignal, OpenTelemetry, or tracing-backend dependencies.
- Prefer a small internal helper for span execution so event naming, measurements, metadata merging, and exception behavior stay consistent.

## Likely Files

- `lib/image_plug.ex`
- `lib/image_plug/request/options.ex`
- New internal helper such as `lib/image_plug/telemetry.ex` or a request-owned telemetry helper.
- Possibly `lib/image_plug/request/runner.ex` if cache/result categories need to be surfaced cleanly.
- Tests under `test/image_plug/*`, likely a focused telemetry test file.

## Validation

- Attach test handlers with `:telemetry.attach_many/4`.
- Assert request start and stop events on successful requests.
- Assert representative stage start and stop events on successful requests.
- Assert stop metadata for parser/plan/origin/cache/processing failures that return responses.
- Assert exception event only for real raised exceptions.
- Assert request paths are omitted by default.
- `mise exec -- mix test`
- `mise exec -- mix compile --warnings-as-errors`
