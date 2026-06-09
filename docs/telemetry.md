# Telemetry

ImagePipe emits telemetry spans for the request lifecycle and its major runtime
stages. Host applications can attach their own logging, metrics, or tracing
integration to those events. ImagePipe doesn't depend on
AppSignal, OpenTelemetry, or any other tracing system.

## Configuration

Set the telemetry prefix as a Plug option:

```elixir
forward "/",
  to: ImagePipe.Plug,
  init_opts: [
    parser: ImagePipe.Parser.Imgproxy,
    sources: [
      path: {ImagePipe.Source.File, root: "/srv/images", root_id: "primary"}
    ],
    telemetry_prefix: [:my_app, :image_pipe]
  ]
```

The default prefix is `[:image_pipe]`. Prefixes must be non-empty lists of
atoms.

## Event names

Events use `:telemetry.span/3` naming conventions. Every span emits a `:start`
event and then either a `:stop` event for normal completion or an `:exception`
event for a raised exception:

```text
telemetry_prefix ++ stage ++ [:start]
telemetry_prefix ++ stage ++ [:stop]
telemetry_prefix ++ stage ++ [:exception]
```

The top-level request span is:

```text
[:image_pipe, :request, :start]
[:image_pipe, :request, :stop]
[:image_pipe, :request, :exception]
```

ImagePipe also emits stage spans for meaningful request phases. The exact set
depends on the routing path. For example, cache hits skip source fetch,
transform execution, output negotiation, encoding, and send streaming spans.

```text
[:image_pipe, :parse, ...]
[:image_pipe, :source, :resolve, ...]
[:image_pipe, :cache, :lookup, ...]
[:image_pipe, :output, :negotiate, ...]
[:image_pipe, :source, :fetch, ...]
[:image_pipe, :source, :fetch_decode, ...]
[:image_pipe, :transform, :execute, ...]
[:image_pipe, :transform, :operation, ...]
[:image_pipe, :transform, :materialize, ...]
[:image_pipe, :encode, ...]
[:image_pipe, :cache, :write, ...]
[:image_pipe, :send, ...]
```

For example, the cache lookup stop event with the default prefix is:

```text
[:image_pipe, :cache, :lookup, :stop]
```

### Source fetch + decode (`[:source, :fetch_decode]`)

`[:image_pipe, :source, :fetch_decode]` wraps source fetch **and** image decode
as one span. By deliberate design it also folds in the two input guards that run
during decode — input-pixel-count validation and source body-size limiting —
rather than emitting separate spans for them.

This fold is intentional. libvips is lazy: a standalone `[:decode]` span would
time loader *construction*, not pixel work (real decode cost is realized later,
during transform materialization and encode). A separate timing span for it
would mislead, the same way per-operation durations would (see below). The
guards are likewise checks, not durationful stages. So their *outcomes* are
reported as stop metadata on this span instead of as their own spans.

The nested `[:source, :fetch]` span (source side effects only) lives inside it.

Success stop metadata:

- `:result` — `:ok`.
- `:load_option` — the shrink-on-load option chosen, `{:shrink, n}`, `{:scale, f}`, or absent when none.
- `:achieved_shrink` — `%{w: float, h: float}` realized shrink, when shrink-on-load fired.
- `:original_dims` — `{w, h}` of the stored image before decode.
- `:loaded_dims` — `{w, h}` actually decoded.

Failure stop metadata (one of two shapes, by failure mode):

- Source-side failure — `:result` is `:source_error`; `:error` is a stable
  category atom (e.g. `:body_too_large` when the source body crosses
  `:max_body_bytes`).
- Decode / input-validation failure — `:result` is `:processing_error`; `:error`
  is a stable category atom (e.g. `:input_limit` when the decoded image exceeds
  `:max_input_pixels`, `:decode` for an undecodable body).

### Transform execute span (`[:transform, :execute]`)

The `[:image_pipe, :transform, :execute]` span wraps the full transform chain.
Its start metadata carries the aggregate plan view:

- `:operation_count` — number of **plan** operations.
- `:operations` — the ordered list of **plan** (semantic) operation-name atoms.

**These two aggregate fields use a deliberately different vocabulary from the
per-operation spans below.** The aggregate `:operations` is the *semantic plan*
view (`:crop_guided`, `:crop_region`, `:canvas`, …). The per-op span's
`:operation` is the *executed-transform* view (`Transform.transform_name/1`),
where e.g. both crop variants execute as `:crop` and a canvas executes as
`:extend_canvas`. A single plan operation can also expand into several executed
transform ops, so `:operation_count` (plan ops) is **not** guaranteed to equal
the number of `[:transform, :operation]` spans. Treat the aggregate as "what
the request asked for" and the per-op spans as "what actually ran".

Stop metadata: `:result` (`:ok` or `:processing_error`).

### Per-operation transform spans (`[:transform, :operation]`)

Each executed operation is wrapped in a nested
`[:image_pipe, :transform, :operation]` span, inside `[:transform, :execute]`.
Its **duration reflects pipeline construction, not pixel compute** — libvips
defers and fuses work to materialization/encode — so use it for tracing
execution *structure* (which operations ran, in what order), never as
per-operation timing. Honest aggregate timing lives on `[:transform, :execute]`.

Start metadata:

- `:operation` — the operation name atom (e.g. `:resize`, `:crop_region`).
- `:index` — zero-based position in the executed chain.
- `:params` — the full operation struct (product-neutral, derived from the
  public request).

Stop metadata: `:result` (`:ok` or `:error`).

### Materialization barrier span (`[:transform, :materialize]`)

Each time the pipeline flushes the lazy libvips state to a RAM-resident buffer it
emits a `[:image_pipe, :transform, :materialize]` span from
`ImagePipe.Transform.Materializer.materialize/1`. This is the **honest
per-barrier timing the per-operation spans deliberately lack**: libvips defers
and fuses pixel work until materialization, so a materialize span's duration is
real flush cost (orientation pixels written, `copy_memory`), not construction
time.

A flush also applies any deferred EXIF/user orientation before copying, so a
materialize span can mark where the displayed frame changes, not only where
pixels reach RAM.

Stop metadata: `:result` (`:ok` or `:materialize_error`). A failed flush surfaces
as a `:stop` carrying `result: :materialize_error` (the callers map it to a decode
error → `415`); a raise inside the flush surfaces as a `[:transform, :materialize,
:exception]` event.

Parenting depends on where the flush happens — there are three cases:

- **mid-chain**, before the first operation that needs random access (right-angle
  rotate, vertical/both flip, smart/object-detect crop): nested under that
  operation's `[:transform, :operation]` span;
- **pipeline-boundary**, when a still-pending EXIF orientation is flushed by the
  plan executor: nested under `[:transform, :execute]` (not under any single
  operation);
- **delivery backstop**, when a chain streamed through without ever materializing
  and the late delivery flush runs after `[:transform, :execute]` has closed:
  nested under the request root.

Every request that decodes and runs the transform pipeline (a cache miss)
materializes at least once: a chain that never materializes mid-pipeline hits the
delivery backstop. Requests served from cache (cache hits, conditional `304`s) skip
decode and transform entirely, so they emit no `[:transform, :materialize]` span
(nor any other transform span).

## Measurements

ImagePipe uses the measurements provided by `:telemetry.span/3`:

- `:start` events include `:system_time` and `:monotonic_time`.
- `:stop` events include `:duration` and `:monotonic_time`.
- `:exception` events include `:duration` and `:monotonic_time`.

Durations use the native time unit from `System.monotonic_time/0`. Handlers can
convert them with `System.convert_time_unit/3` for a specific display unit.

HTTP cache decision events aren't spans. ImagePipe emits them with
`Telemetry.execute/4`, and they're sent with empty measurements:

```text
[:image_pipe, :http_cache, :prepare]
[:image_pipe, :http_cache, :conditional, :match]
[:image_pipe, :http_cache, :fallback, :no_store]
[:image_pipe, :http_cache, :cache_hit, :headers]
```

## Metadata

Metadata is product-neutral and free of sensitive data (no secrets, credentials,
or source-derived paths). Cardinality is a consumer concern — handlers may safely
accept high-cardinality fields and project or aggregate them as needed. Common
fields are:

- `:parser` - the configured parser module.
- `:request_method` - the HTTP method.
- `:result` - the stable outcome category.
- `:status` - the response status when known.
- `:cache` - cache status when relevant.
- `:output_mode` - `:automatic` or `:explicit` when known.
- `:output_format` - the resolved output format when known.
- `:source_kind` - `:path`, `:url`, `:object`, or `:reference` on source spans.
- `:source_adapter_kind` - `:file`, `:http`, `:s3`, or `:custom` on source spans.
- `:error` - a stable error category when known.

Exception events include the metadata added by `:telemetry.span/3`, including
`:kind`, `:reason`, and `:stacktrace`.

All span events also include `:telemetry_span_context`, which
`:telemetry.span/3` injects for correlating the events from the same span. Treat
it as correlation data, not as a metrics dimension.

ImagePipe doesn't emit full request paths by default. Imgproxy-style paths can
contain signatures, filenames, and source-shaped user data, and often have high
cardinality. Host applications that need path-level observability should add
that data in their own handlers with the relevant privacy and cardinality
controls.

## Result values

Request and stage spans use narrow result atoms:

- `:ok`
- `:parser_error`
- `:plan_error`
- `:source_error`
- `:cache_error`
- `:materialize_error`
- `:processing_error`
- `:error`

Use `:error` for stage-local failures that aren't otherwise classified at that
stage. The request span maps returned failures into the more specific request
outcome categories in this list.

Representative stage → result mappings:

- `[:source, :fetch_decode]` → `:ok`, `:source_error` (e.g. `error: :body_too_large`),
  or `:processing_error` (e.g. `error: :input_limit`, `:decode`).
- `[:transform, :execute]` → `:ok` or `:processing_error`.
- `[:transform, :materialize]` → `:ok` or `:materialize_error`.
- `[:output, :negotiate]` → `:ok` or a negotiation failure category.

The `:error` field is a stable category atom (`ImagePipe.Error.tag/1`), never a
raw message or source-derived path.

## Content-aware crop detection

Detection-aware crops (`g:obj:face`, `g:obj:car`, `g:obj`, `c:W:H:obj:…`, and
face-assisted `g:sm`) report detection two ways, depending on whether any
detection actually ran.

When a detector is configured, ImagePipe wraps the detector invocation in a
`[:image_pipe, :transform, :detect]` span whose duration reflects real inference
work (useful for spotting model cold-start cost). Stop metadata:

- `:classes` - the requested detection classes, e.g. `["face"]` or `:all`.
- `:regions` - the total number of regions the detector returned.
- `:result` - the detector outcome, one of:
  - `:detected` - the detector returned at least one region.
  - `:no_regions` - the detector ran but found nothing (no matching object in the
    frame). This is a normal result, **not** a failure; the crop falls back to
    libvips attention saliency.
  - `:unavailable` - the configured detector reported it is unavailable.
  - `:error` - the detector raised, errored, or returned a malformed result.

`:result` reflects the *detector* outcome, not the final crop decision: a
`:detected` result whose boxes all fall outside the image still degrades to
attention downstream.

### Per-model spans (Composite detector)

When using the bundled Composite detector (the default), ImagePipe also emits a
nested `[:image_pipe, :transform, :detect, :model]` span **per child detector
that ran**. These spans are emitted inside the outer `[:transform, :detect]`
span. Stop metadata:

- `:detector` - the child detector module that ran (e.g.
  `ImagePipe.Transform.Detector.ImageVision.Face`).
- `:model` - the child's `identity/1` result for this request (e.g.
  `{ImagePipe.Transform.Detector.ImageVision.Face, {"opencv/face_detection_yunet", "face_detection_yunet_2023mar.onnx"}}`).
- `:classes` - the class subset routed to this child for the request (a list of
  class name strings, or `:all`).
- `:regions` - the number of regions this child returned.

To determine the **effective detected class set** from per-model spans: take the
union of all `:classes` values across all `:stop` events for a given request. A
class that was requested but does not appear in any per-model span was unknown to
all configured detectors and was silently dropped (best-effort).

> **Custom-detector authors:** keep your `identity/1` return value free of
> secrets — it appears in these per-model spans, which fan out to every attached
> handler including third-party exporters.

When **no** detector is configured, no detection runs, so there is no span.
Instead ImagePipe emits a one-shot (non-span) marker:

```text
[:image_pipe, :transform, :detect, :skipped]
```

with empty measurements and metadata `%{classes: [...], result: :no_detector}`.

The two unfulfillable-but-configured span results (`:unavailable`, `:error`) and
the `:skipped` one-shot (`:no_detector`) all mark a face-aware request that fell
back to attention saliency; the opt-in default Logger escalates all three to
`:warning`. The normal `:no_regions` and `:detected` span results log at the
base level.

For face-assisted smart crop (`g:sm` with `smart_crop_face_detection`), when a
face is found ImagePipe blends the attention point with the face centroid. It
emits a one-shot (non-span) marker recording the skew:

```text
[:image_pipe, :transform, :detect, :blend]
```

with empty measurements and metadata:

- `:attention` - the pure libvips saliency point `{x, y}` (normalized 0..1).
- `:face` - the area-weighted face centroid `{x, y}` (normalized 0..1).
- `:blended` - the point actually used: `(1 - weight)·attention + weight·face`.
- `:weight` - the face-assist blend weight (ImagePipe's approximation).

Subtract `:attention` from `:blended` for how far the face pulled the crop. The
coordinates are product-neutral and derived from the public request, so they are
safe to emit. This marker fires only when a face is detected; no face means a
plain attention crop and no blend event. The default Logger renders it at the
base level.

Cache-related metadata may also include:

- `cache: :disabled`
- `cache: :hit`
- `cache: :miss`
- `cache: :read_error`
- `cache: :write`
- `cache: :stage_skipped`
- `cache: :stage_error`
- `cache: :write_error`
- `cache: :stage_abandoned`
- `cache: :stage_cleanup_error`

Streamed cache misses may also emit the one-shot `[:cache, :stage]` event (sent
with `Telemetry.execute/4`, not a span) with:

- `cache: :stage_skipped` and `reason: :too_large` when the staging sink crosses
  `:max_body_bytes`.
- `cache: :stage_abandoned` when ImagePipe aborts a staged entry
  because delivery stopped early, the owner process exited, or the stream failed.
- `cache: :stage_error` when opening or writing the staging sink fails before
  commit.
- `cache: :stage_cleanup_error` when abort cleanup fails after the response path
  has already failed open.

Cache sink commits use the existing `[:cache, :write, ...]` span. A
successful commit stop event includes `cache: :write`. A commit error after
successful streamed delivery includes `cache: :write_error` and
`result: :cache_error`, but the response still fails open because the body was
already delivered.

Generated CDN HTTP cache handling emits non-span events:

- `[:image_pipe, :http_cache, :prepare]` with `:effective_mode`,
  `:byte_identity`, and `:etag`.
- `[:image_pipe, :http_cache, :conditional, :match]` with `method: :get`.
- `[:image_pipe, :http_cache, :fallback, :no_store]` with `:adapter`,
  `:source_kind`, and `:reason`.
- `[:image_pipe, :http_cache, :cache_hit, :headers]` with booleans for `:etag`,
  `:generated_cache_headers`, and `:representation_headers`.

These events don't include request paths, source identities, cache keys, or ETag
values.

## Output dimension clamp (`[:output, :clamp]`)

When the realized final image exceeds the effective result caps — the tighter of
the host `max_result_width`/`max_result_height`/`max_result_pixels` config and the
negotiated output encoder's hard limit (`min(host, encoder)`) — ImagePipe
uniformly downscales it to fit before encoding and emits a one-shot (non-span)
marker. This both keeps encoding from failing (WebP caps each dimension at 16383,
AVIF at 16384, JPEG at 65535; PNG effectively unbounded) and serves the host result cap as a
downscale rather than an error (imgproxy `limitScale` parity). The common trigger
is the host cap (default 8192 per axis), which is below the encoder limits.

```text
[:image_pipe, :output, :clamp]
```

Measurements:

- `:scale` — the uniform downscale factor applied (a float `< 1.0`).

Metadata:

- `:format` — the negotiated output format atom (e.g. `:webp`, `:avif`).
- `:source_dimensions` — `{w, h}` before the clamp.
- `:dimensions` — `{w, h}` after the clamp.
- `:limits` — the effective caps applied: `%{max_width, max_height, max_pixels}` (each a `pos_integer` or `:infinity`).

This metadata is product-neutral and non-sensitive (no URLs, secrets, or PII).

The opt-in default Logger attaches to this event and renders it at `:warning`,
matching imgproxy's `slog.Warn` for the same condition, e.g.:

```text
image_pipe output clamp: 18000x9000 -> 8192x4096 for webp (caps w:8192 h:8192 px:40000000)
```

## Attaching handlers

A host application can attach to all ImagePipe span events with
`:telemetry.attach_many/4`:

```elixir
defmodule MyApp.ImagePipeTelemetry do
  require Logger

  @stages [
    [:request],
    [:parse],
    [:source, :resolve],
    [:cache, :lookup],
    [:output, :negotiate],
    [:source, :fetch],
    [:source, :fetch_decode],
    [:transform, :execute],
    [:transform, :operation],
    [:transform, :materialize],
    [:encode],
    [:cache, :stage],
    [:cache, :write],
    [:send]
  ]

  def attach do
    events =
      for stage <- @stages,
          suffix <- [:start, :stop, :exception] do
        [:image_pipe | stage] ++ [suffix]
      end

    :telemetry.attach_many(
      "my-app-image-pipe",
      events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(event, measurements, metadata, _config) do
    Logger.debug(
      "image_pipe event=#{inspect(event)} " <>
        "measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
    )
  end
end
```

When customizing `telemetry_prefix`, attach to that same prefix instead of
`[:image_pipe]`.

## Tracing (opt-in)

The events above are raw `:telemetry` events. ImagePipe also ships an **opt-in
span tracer** that consumes those events, reconstructs correctly-nested
distributed-trace-shaped spans (one `trace_id` per request, parent/child
relationships preserved across the `[:transform, :execute]` /
`[:transform, :operation]` / `[:transform, :materialize]` nesting and across the
request → `SourceSession` → `Producer` process seams), and hands each finished
span to a pluggable exporter as an `ImagePipe.Telemetry.Trace.Span`.

The tracer is **not** attached automatically. A host opts in with
`ImagePipe.Telemetry.attach_tracer/1` and removes it with
`ImagePipe.Telemetry.detach_tracer/0`. Both are host-startup configuration, so
`attach_tracer/1` **raises** `ArgumentError` on invalid options rather than
returning a tagged error.

```elixir
# Attach the bundled stdlib-Logger exporter:
ImagePipe.Telemetry.attach_tracer(exporter: ImagePipe.Telemetry.Trace.LogExporter)

# ... later ...
ImagePipe.Telemetry.detach_tracer()
```

### Options

| Option            | Type            | Default                   | Meaning                                                                 |
| ----------------- | --------------- | ------------------------- | ----------------------------------------------------------------------- |
| `:exporter`       | module (atom)   | — (required)              | Module implementing the `ImagePipe.Telemetry.Trace.Exporter` behaviour. |
| `:prefix`         | list of atoms   | `[:image_pipe]`           | Telemetry event prefix to subscribe to. Reuses `ImagePipe.Telemetry.default_prefix()`; match your configured `telemetry_prefix`. |
| `:extract_inbound`| boolean         | `false`                   | Extract an inbound W3C `traceparent` header so the root span continues an upstream trace. Off by default — only enable behind a trusted edge. |
| `:finch_spans`    | boolean         | `true`                    | Also capture physical Finch wire spans for outbound source fetches.     |

`attach_tracer/1` raises `ArgumentError` when an option is unknown, has the wrong
type, `:exporter` is missing, or the exporter module is not loaded / does not
export `export/1`.

### The exporter contract

A host implements `ImagePipe.Telemetry.Trace.Exporter`:

```elixir
@callback export(ImagePipe.Telemetry.Trace.Span.t()) :: :ok
```

- `export/1` is called **synchronously** in the process that emitted the span's
  `:stop` / `:exception`. Keep it cheap and non-blocking — hand real I/O off to a
  batch processor. It must return `:ok` and should not raise.
- Span **attributes are pre-filtered for sensitivity** by the capture layer
  (allowlist only — source URLs, request paths, signatures, and tokens are never
  copied in). Exporters that fan out to third parties remain responsible for
  their own egress policy.
- The allowlist covers **attributes only**. A span's `status_message` and the
  `reason` on a folded `exception` event carry the raw exception reason
  (`inspect/1`, standard tracing behavior) and are **not** allowlist-filtered,
  so an exporter that renders them to third parties should be aware they may
  embed an exception message. (The bundled `LogExporter` renders neither.)

### `LogExporter`

`ImagePipe.Telemetry.Trace.LogExporter` is the bundled default. It is
**stateless and flat by design**: it logs one structured `Logger.info` line per
completed span as that span closes, in the process that emitted it. It does
**not** buffer spans into a tree or wait for a root to close — parentage is
carried in the `parent=` field so a downstream log pipeline can reconstruct
nesting.

```
image_pipe.trace trace=<trace_id> span=<span_id> parent=<parent_span_id|-> <name> dur=<duration_native|-> status=<ok|error|unset>
```

### Inbound extraction and sampling

Inbound `traceparent` extraction is **opt-in** (`extract_inbound: true`) because
trusting an inbound trace header from an untrusted client lets a caller pin your
`trace_id`; enable it only behind a gateway you control. When enabled and a valid
W3C `traceparent` is present, the request root span continues that trace and
parents to the inbound span; otherwise it mints a fresh root.

**Sampling is deferred to the host.** ImagePipe propagates `trace_flags` but does
not implement a sampler. A host that wants head- or tail-based sampling does it in
its exporter (e.g. drop spans whose `trace_flags` indicate "not sampled", or
batch and sample in the downstream collector).
