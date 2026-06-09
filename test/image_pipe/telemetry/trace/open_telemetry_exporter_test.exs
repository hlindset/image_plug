defmodule ImagePipe.Telemetry.Trace.OpenTelemetryExporterTest do
  use ExUnit.Case, async: false

  require Record
  # Read the #span{} the SDK delivers (test-only — reading, not constructing).
  Record.defrecordp(
    :otel_span,
    :span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  alias ImagePipe.Telemetry.Trace.{OpenTelemetryExporter, Span}

  setup do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    on_exit(fn -> :otel_simple_processor.set_exporter(:none, []) end)
    :ok
  end

  test "replays a span carrying OUR trace_id, with an OTel-minted (different) span_id" do
    span = %Span{
      trace_id: "0123456789abcdef0123456789abcdef",
      span_id: "89abcdef01234567",
      parent_span_id: "fedcba9876543210",
      name: "image_pipe.request",
      kind: :server,
      start_time: System.system_time(),
      duration_native: 1_000,
      status: :ok,
      trace_flags: 1
    }

    assert :ok = OpenTelemetryExporter.export(span)

    assert_receive {:span, rec}, 1_000
    assert otel_span(rec, :trace_id) == 0x0123456789ABCDEF0123456789ABCDEF
    minted = otel_span(rec, :span_id)
    assert is_integer(minted) and minted != 0
    assert minted != 0x89ABCDEF01234567
    assert otel_span(rec, :parent_span_id) == 0xFEDCBA9876543210
    assert otel_span(rec, :name) == "image_pipe.request"
    assert otel_span(rec, :kind) == :server
  end
end
