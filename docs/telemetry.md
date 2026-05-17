# Telemetry

ImagePlug emits telemetry spans for the request lifecycle and its major runtime
stages. The events are intended for host applications to attach their own
logging, metrics, or tracing integration. ImagePlug does not depend on
AppSignal, OpenTelemetry, or any other tracing backend.

## Configuration

The telemetry prefix is configured as a Plug option:

```elixir
forward "/",
  to: ImagePlug,
  init_opts: [
    root_url: "http://localhost:4000",
    parser: ImagePlug.Parser.Imgproxy,
    telemetry_prefix: [:my_app, :image_plug]
  ]
```

The default prefix is `[:image_plug]`. Prefixes must be non-empty lists of
atoms.

## Event Names

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
[:image_plug, :origin, :identity, ...]
[:image_plug, :cache, :lookup, ...]
[:image_plug, :output, :negotiate, ...]
[:image_plug, :origin, :fetch_decode, ...]
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

Durations use the native time unit from `System.monotonic_time/0`. Convert them
with `System.convert_time_unit/3` in handlers when a specific display unit is
needed.

## Metadata

Metadata is intentionally low-cardinality and product-neutral. Common fields are:

- `:parser` - the configured parser module.
- `:request_method` - the HTTP method.
- `:result` - the stable outcome category.
- `:status` - the response status when known.
- `:cache` - cache status when relevant.
- `:output_mode` - `:automatic` or `:explicit` when known.
- `:output_format` - the resolved output format when known.
- `:error` - a stable error category when known.

Exception events include the metadata added by `:telemetry.span/3`, including
`:kind`, `:reason`, and `:stacktrace`.

All span events also include `:telemetry_span_context`, which is injected by
`:telemetry.span/3` for correlating the events from the same span. Treat it as
correlation data, not as a metrics dimension.

ImagePlug does not emit full request paths by default. Imgproxy-style paths can
contain signatures, filenames, and origin-shaped user data, and they are often
high-cardinality. Host applications that need path-level observability should
add that data in their own handlers with the relevant privacy and cardinality
controls.

## Result Values

Request and stage spans use narrow result atoms:

- `:ok`
- `:parser_error`
- `:plan_error`
- `:origin_error`
- `:cache_error`
- `:processing_error`
- `:error`

The `:error` value is reserved for stage-local failures that are not otherwise
classified at that stage. The request span maps returned failures into the more
specific request outcome categories above.

Cache-related metadata may also include:

- `cache: :disabled`
- `cache: :hit`
- `cache: :miss`
- `cache: :read_error`
- `cache: :write_skipped`
- `cache: :write_error`

`cache: :write_skipped` is emitted on the `[:encode, :stop]` stage when a
cacheable response exceeds the configured cache body limit before a cache write
is attempted.

## Attaching Handlers

A host application can attach to all ImagePlug span events with
`:telemetry.attach_many/4`:

```elixir
defmodule MyApp.ImagePlugTelemetry do
  require Logger

  @stages [
    [:request],
    [:parse],
    [:origin, :identity],
    [:cache, :lookup],
    [:output, :negotiate],
    [:origin, :fetch_decode],
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

If `telemetry_prefix` is customized, attach to that same prefix instead of
`[:image_plug]`.

## Timing Notes

Stage spans are coarse by design. ImagePlug does not emit per-operation
transform spans in this pass.

Image processing is backed by libvips through the `image` package. libvips is
demand-driven: operation calls can do real setup and metadata work, but pixel
evaluation may be pulled later by a sink such as materialization, cache encoding,
or response encoding. ImagePlug also materializes inside the transform stage for
sequential input access and between multiple pipelines, so even stage timing is
boundary timing rather than pure CPU attribution.

Because of that, request and stage spans are the stable observability surface.
They should not be interpreted as precise per-transform CPU timings. libvips has
lower-level progress and profiling mechanisms, but Vix does not expose them as
per-request `:telemetry` events that ImagePlug can safely forward today.
