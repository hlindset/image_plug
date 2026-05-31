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
[:image_pipe, :transform, :execute, ...]
[:image_pipe, :encode, ...]
[:image_pipe, :cache, :stage, ...]
[:image_pipe, :cache, :write, ...]
[:image_pipe, :send, ...]
```

For example, the cache lookup stop event with the default prefix is:

```text
[:image_pipe, :cache, :lookup, :stop]
```

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

Metadata is intentionally low-cardinality and product-neutral. Common fields are:

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
- `:processing_error`
- `:error`

Use `:error` for stage-local failures that aren't otherwise classified at that
stage. The request span maps returned failures into the more specific request
outcome categories in this list.

## Content-aware crop detection

Face-aware crops (`g:obj:face`, `c:W:H:obj:face`, and face-assisted `g:sm`)
emit a `[:image_pipe, :transform, :detect]` span around detector inference.
Every face-aware request emits exactly one detect span, including when no
detector is configured (so the fallback is always observable). Stop metadata:

- `:classes` - the requested detection classes, e.g. `["face"]`.
- `:regions` - the number of regions the detector returned.
- `:result` - the detector outcome, one of:
  - `:detected` - the detector returned at least one region.
  - `:no_regions` - the detector ran but found nothing (no face in the frame).
    This is a normal result, **not** a failure; the crop falls back to libvips
    attention saliency.
  - `:unavailable` - the configured detector reported it is unavailable.
  - `:error` - the detector raised, errored, or returned a malformed result.
  - `:no_detector` - the request asked for a face-aware crop but no detector is
    configured.

The last three (`:unavailable`, `:error`, `:no_detector`) mark a face-aware
request that **could not be fulfilled** and degraded to attention saliency. The
opt-in default Logger escalates those three to `:warning`; `:no_regions` and
`:detected` log at the base level. `:result` reflects the *detector* outcome,
not the final crop decision: a `:detected` result whose boxes all fall outside
the image still degrades to attention downstream.

The detect span duration reflects real inference work and is useful for spotting
model cold-start cost. The `:no_detector` span performs no detection, so its
duration is near-zero by design.

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

Streamed cache misses may also emit `[:cache, :stage, :stop]` with:

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
    [:transform, :execute],
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
