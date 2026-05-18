# Telemetry

ImagePlug emits telemetry spans for the request lifecycle and its major runtime
stages. Host applications can attach their own logging, metrics, or tracing
integration to those events. ImagePlug doesn't depend on
AppSignal, OpenTelemetry, or any other tracing system.

## Configuration

Set the telemetry prefix as a Plug option:

```elixir
forward "/",
  to: ImagePlug,
  init_opts: [
    parser: ImagePlug.Parser.Imgproxy,
    sources: [
      path: {ImagePlug.Source.File, root: "/srv/images", root_id: "primary"}
    ],
    telemetry_prefix: [:my_app, :image_plug]
  ]
```

The default prefix is `[:image_plug]`. Prefixes must be non-empty lists of
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
[:image_plug, :request, :start]
[:image_plug, :request, :stop]
[:image_plug, :request, :exception]
```

ImagePlug also emits stage spans for meaningful request phases:

```text
[:image_plug, :parse, ...]
[:image_plug, :source, :resolve, ...]
[:image_plug, :cache, :lookup, ...]
[:image_plug, :output, :negotiate, ...]
[:image_plug, :source, :fetch, ...]
[:image_plug, :transform, :execute, ...]
[:image_plug, :encode, ...]
[:image_plug, :cache, :write, ...]
[:image_plug, :send, ...]
```

For example, the cache lookup stop event with the default prefix is:

```text
[:image_plug, :cache, :lookup, :stop]
```

## Measurements

ImagePlug uses the measurements provided by `:telemetry.span/3`:

- `:start` events include `:system_time` and `:monotonic_time`.
- `:stop` events include `:duration` and `:monotonic_time`.
- `:exception` events include `:duration` and `:monotonic_time`.

Durations use the native time unit from `System.monotonic_time/0`. Handlers can
convert them with `System.convert_time_unit/3` for a specific display unit.

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

ImagePlug doesn't emit full request paths by default. Imgproxy-style paths can
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

Cache-related metadata may also include:

- `cache: :disabled`
- `cache: :hit`
- `cache: :miss`
- `cache: :read_error`
- `cache: :write_skipped`
- `cache: :write_error`

The `[:encode, :stop]` stage emits `cache: :write_skipped` when a cacheable
response exceeds the configured cache body limit before ImagePlug attempts a
cache write.

## Attaching handlers

A host application can attach to all ImagePlug span events with
`:telemetry.attach_many/4`:

```elixir
defmodule MyApp.ImagePlugTelemetry do
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
    [:cache, :write],
    [:send]
  ]

  def attach do
    events =
      for stage <- @stages,
          suffix <- [:start, :stop, :exception] do
        [:image_plug | stage] ++ [suffix]
      end

    :telemetry.attach_many(
      "my-app-image-plug",
      events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(event, measurements, metadata, _config) do
    Logger.debug(
      "image_plug event=#{inspect(event)} " <>
        "measurements=#{inspect(measurements)} metadata=#{inspect(metadata)}"
    )
  end
end
```

When customizing `telemetry_prefix`, attach to that same prefix instead of
`[:image_plug]`.
