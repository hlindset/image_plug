# Cookbook: OpenTelemetry traces to Jaeger (local)

ImagePipe emits `:telemetry` spans and ships an opt-in exporter that replays them into
your OpenTelemetry SDK (preserving ImagePipe's trace_id). This sends traces to a local
Jaeger.

> The `fiddle/` demo app in this repo wires exactly this up (gated behind `FIDDLE_OTEL=1`)
> — see `fiddle/docker-compose.yml`, the `:opentelemetry`/`:opentelemetry_exporter` config
> in `fiddle/config/config.exs`, and the `attach_tracer/1` call in
> `fiddle/lib/image_pipe_fiddle/application.ex` for a runnable example.

## 1. Run Jaeger

```yaml
# docker-compose.yml
services:
  jaeger:
    image: cr.jaegertracing.io/jaegertracing/jaeger:2.19.0
    ports: ["16686:16686", "4317:4317", "4318:4318"]
```

`docker compose up -d`, then open http://localhost:16686. Jaeger v2 accepts OTLP
natively on 4317 (gRPC) and 4318 (HTTP).

## 2. Add the OTel SDK (host side)

```elixir
# mix.exs
# list :opentelemetry_exporter BEFORE :opentelemetry so the exporter app
# starts first (otherwise the SDK's processor can't reach it at boot)
{:opentelemetry_exporter, "~> 1.8"},
{:opentelemetry, "~> 1.7"},
```

ImagePipe itself only needs `:opentelemetry_api` (it declares it optional); you bring
the SDK. Adding `:opentelemetry` pulls `:opentelemetry_api` in transitively.

## 3. Point the SDK at Jaeger

```elixir
# config/config.exs
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp,
  # the Jaeger "service" name (otherwise a default like "Erlang/OTP"); ImagePipe
  # itself only sets the `image_pipe` instrumentation scope, not the resource
  resource: [service: %{name: "my_app"}]

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: "http://localhost:4318"
```

```elixir
# config/test.exs — never export during tests
config :opentelemetry, traces_exporter: :none
```

(For releases you can instead put the SDK config in `config/runtime.exs` and read the
endpoint from an env var; just keep the test override.)

## 4. Activate at startup

```elixir
ImagePipe.Telemetry.attach_tracer(
  exporter: ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
  extract_inbound: true
)
```

If `:opentelemetry_api` isn't present this raises at startup. Issue a request, wait a
few seconds for the batch processor to flush, then find the `image_pipe.request` trace
in Jaeger — child spans (`image_pipe.{send,encode,output.negotiate,transform.execute,
transform.operation,…}`) are nested under it. The root span itself may show a
"missing parent" note in Jaeger when ImagePipe originates the trace: its synthetic
remote parent is what forces ImagePipe's `trace_id` onto the OTel trace (use
`extract_inbound: true` behind a traced caller to make it a real child instead).

## Troubleshooting: no traces appear

The exporter detects the OTel API at **compile time** (a `Code.ensure_loaded?` guard
baked into `image_pipe`). If you added the SDK to an already-compiled project,
`image_pipe` may have been compiled *without* `:opentelemetry_api` and the exporter
stays dormant — `ImagePipe.Telemetry.Trace.OpenTelemetryExporter.available?/0` returns
`false`. Force a recompile so it picks the API up:

```sh
mix deps.compile image_pipe --force   # or: mix clean && mix compile
```

A fresh build (deps fetched before the first compile) doesn't hit this, because the
compiler sees `:opentelemetry_api` while compiling `image_pipe`.
