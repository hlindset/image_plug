# Cookbook: OpenTelemetry traces to Jaeger (local)

ImagePipe emits `:telemetry` spans and ships an opt-in exporter that replays them into
your OpenTelemetry SDK (preserving ImagePipe's trace_id). This sends traces to a local
Jaeger all-in-one.

## 1. Run Jaeger

```yaml
# docker-compose.yml
services:
  jaeger:
    image: jaegertracing/all-in-one:1.60
    ports: ["16686:16686", "4317:4317", "4318:4318"]
```

`docker compose up -d`, then open http://localhost:16686.

## 2. Add the OTel SDK (host side)

```elixir
# mix.exs
{:opentelemetry, "~> 1.7"},
{:opentelemetry_exporter, "~> 1.8"},
```

ImagePipe itself only needs `:opentelemetry_api` (it declares it optional); you bring
the SDK.

## 3. Point the SDK at Jaeger

```elixir
# config/runtime.exs
config :opentelemetry, span_processor: :batch, traces_exporter: :otlp
config :opentelemetry_exporter, otlp_protocol: :http_protobuf, otlp_endpoint: "http://localhost:4318"
```

Set your `service.name` via `OTEL_RESOURCE_ATTRIBUTES` / the SDK resource — ImagePipe
sets only the `image_pipe` instrumentation scope.

## 4. Activate at startup

```elixir
ImagePipe.Telemetry.attach_tracer(
  exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
  extract_inbound: true
)
```

If `:opentelemetry_api` isn't present this raises at startup. Issue a request and find
the `image_pipe.request` trace in Jaeger.
