defmodule ImagePipe.Telemetry.Trace.Exporter do
  @moduledoc """
  Behaviour a host implements to receive captured spans, one per completed span.

  `export/1` is called synchronously in the process that emitted the span's `:stop`/
  `:exception`. Keep it cheap and non-blocking — hand off to a batch processor for any
  real I/O. It must return `:ok` and should not raise. Attributes are pre-filtered for
  sensitivity (`ImagePipe.Telemetry.Trace.Capture` allowlists them), but exporters that
  fan out to third parties remain responsible for their own egress policy.
  """
  alias ImagePipe.Telemetry.Trace.Span

  @callback export(Span.t()) :: :ok
end
