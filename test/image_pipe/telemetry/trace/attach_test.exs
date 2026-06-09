defmodule ImagePipe.Telemetry.Trace.AttachTest do
  use ExUnit.Case, async: false
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace.LogExporter

  setup do
    on_exit(fn -> Telemetry.detach_tracer() end)
    :ok
  end

  test "attach_tracer succeeds with a valid exporter" do
    assert Telemetry.attach_tracer(exporter: LogExporter) == :ok
  end

  test "attach_tracer raises on unknown option" do
    assert_raise ArgumentError, fn ->
      Telemetry.attach_tracer(exporter: LogExporter, bogus: 1)
    end
  end

  test "attach_tracer raises when exporter is missing" do
    assert_raise ArgumentError, fn -> Telemetry.attach_tracer([]) end
  end

  test "attach_tracer raises when exporter module is not loadable" do
    assert_raise ArgumentError, fn -> Telemetry.attach_tracer(exporter: NotARealModule) end
  end

  test "attach_tracer raises when module is loadable but does not export export/1" do
    assert_raise ArgumentError, fn -> Telemetry.attach_tracer(exporter: Enum) end
  end
end
