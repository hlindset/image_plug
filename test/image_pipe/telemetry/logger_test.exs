defmodule ImagePipe.Telemetry.LoggerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ImagePipe.Telemetry

  setup do
    on_exit(fn -> Telemetry.detach_default_logger() end)
    :ok
  end

  test "attach is idempotent and detach removes the handler" do
    assert :ok = Telemetry.attach_default_logger()
    assert :ok = Telemetry.attach_default_logger()
    assert :ok = Telemetry.detach_default_logger()
    assert {:error, :not_found} = Telemetry.detach_default_logger()
  end

  test "logs a cache lookup hit at the configured level" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :cache, :lookup, :stop],
          %{duration: System.convert_time_unit(2, :millisecond, :native)},
          %{result: :ok, cache: :hit}
        )
      end)

    assert log =~ "cache lookup: hit"
  end

  test "escalates error outcomes to warning" do
    Telemetry.attach_default_logger(level: :info)

    log =
      capture_log(fn ->
        :telemetry.execute(
          [:image_pipe, :cache, :write, :stop],
          %{duration: 1000},
          %{result: :cache_error, cache: :write_error, error: :boom}
        )
      end)

    assert log =~ "[warning]"
    assert log =~ "cache write"
  end

  test "renders a transform operation with name and index" do
    Telemetry.attach_default_logger(level: :debug)

    # capture at :debug explicitly so the test does not depend on the ambient
    # Logger level.
    log =
      capture_log([level: :debug], fn ->
        :telemetry.execute(
          [:image_pipe, :transform, :operation, :stop],
          %{duration: 500},
          %{operation: :resize, index: 0, params: %{}, result: :ok}
        )
      end)

    assert log =~ "transform: resize (#1)"
  end
end
